-module(erlimem_session).
-behaviour(gen_server).

-include("erlimem.hrl").
-include_lib("imem/include/imem_sql.hrl").

-record(state, {
    stmts       = [],
    connect_conf,
    connection,
    event_pids  = [],
    buf         = {0, <<>>},
    schema,
    seco = '$not_a_session',
    maxrows,
    authorized = false,
    unauthIdleTmr = '$not_a_timer'
}).

-record(stmt, {
    fsm
}).

% session APIs
-export([close/1, exec/3, exec/4, exec/5, run_cmd/3, get_stmts/1, auth/4]).

% gen_server callbacks
-export([start_link/2, init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, add_stmt_fsm/3]).

-spec start_link(local | local_sec
                 | {tcp, inet:ip_address() | inet:hostname(),
                 inet:port_number()}, atom()) ->
    {ok, pid()} | {error, any()}.
start_link(Connect, Schema) ->
    case gen_server:start_link(?MODULE, [Connect, Schema], [{spawn_opt, [{fullsweep_after, 0}]}]) of
        {ok, _} = Success -> Success;
        Error ->
            ?Error("~p failed to start ~p", [?MODULE, Error]),
            Error
    end.

%
% interface functions
%

-spec close({atom(), pid()} | {atom(), pid(), pid()}) -> ok.
close({?MODULE, Pid}) ->
    case catch is_process_alive(Pid) of
        true ->	gen_server:call(Pid, stop);
        _ -> ok
    end;
close({?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {close_statement, StmtRef}).

-spec exec(list(), list(), {erlimem_session, pid()}) -> term().
exec(StmtStr, Params, Ctx) -> exec(StmtStr, 0, Params, Ctx).

-spec exec(list(), integer(), list(), {erlimem_session, pid()}) -> term().
exec(StmtStr, BufferSize, Params, Ctx) -> run_cmd(exec, [Params, StmtStr, BufferSize], Ctx).

-spec exec(list(), integer(), fun(), list(), {erlimem_session, pid()}) -> term().
exec(StmtStr, BufferSize, Fun, Params, Ctx) -> run_cmd(exec, [Params, StmtStr, BufferSize, Fun], Ctx).

-spec run_cmd(atom(), list(), {atom(), pid()}) -> term().
run_cmd(login, Args, {?MODULE, Pid}) when is_list(Args) ->
    case gen_server:call(Pid, [login|Args], ?IMEM_TIMEOUT) of
        SKey when is_integer(SKey) ->
            Schema = gen_server:call(Pid, [schema], ?IMEM_TIMEOUT),
            gen_server:call(Pid, {check_schema, Schema, SKey}, ?IMEM_TIMEOUT);
        Error -> Error
    end;
run_cmd(Cmd, Args, {?MODULE, Pid}) when is_list(Args) -> gen_server:call(Pid, [Cmd|Args], ?IMEM_TIMEOUT).

-spec auth(AppId :: atom(), SessionId :: any(),
           Credentials :: tuple(), {?MODULE, pid()}) ->
    ok | {ok,[DDCredentialRequest :: tuple()]} | no_return().
auth(AppId, SessionId, Credentials, {?MODULE, Pid}) when is_atom(AppId) ->
    case gen_server:call(Pid, {auth, AppId, SessionId, Credentials}, ?IMEM_TIMEOUT) of
        {error, {{E,M},ST}} -> throw({{E,M},ST});
        {SKey,[]} -> gen_server:call(Pid, {skey, SKey, true}, ?IMEM_TIMEOUT);
        {SKey,Steps} when is_list(Steps) ->
            gen_server:call(Pid, {skey, SKey, false}, ?IMEM_TIMEOUT),
            {ok, Steps}
    end.

-spec add_stmt_fsm(pid()|list(pid()), {atom(), pid()}, {atom(), pid()}) -> ok.
add_stmt_fsm(StmtRefs, StmtFsm, {?MODULE, Pid}) when is_list(StmtRefs) -> 
    [add_stmt_fsm(SR, StmtFsm, {?MODULE, Pid}) || SR <- StmtRefs];
add_stmt_fsm(StmtRef, StmtFsm, {?MODULE, Pid}) -> 
    gen_server:call(Pid, {add_stmt_fsm, StmtRef, StmtFsm}, ?SESSION_TIMEOUT).

-spec get_stmts(list() | {atom(), pid()}) -> [pid()].
get_stmts({?MODULE, Pid}) -> gen_server:call(Pid, get_stmts, ?SESSION_TIMEOUT);
get_stmts(PidStr)         -> gen_server:call(list_to_pid(PidStr), get_stmts, ?SESSION_TIMEOUT).

%
% gen_server callbacks
%
init([Connect, Schema]) when is_binary(Schema); is_atom(Schema) ->
    try
        State = #state{schema = Schema,
                       unauthIdleTmr = erlang:send_after(?UNAUTHIDLETIMEOUT, self(), unauthorized),
                       connect_conf = Connect},
        case connect(Connect) of
            ok ->
                {ok,
                 case Connect of
                     local_sec -> State#state{connection = local_sec};
                     local ->
                         catch erlang:cancel_timer(State#state.unauthIdleTmr),
                         State#state{connection = local, authorized = true,
                                     unauthIdleTmr = '$not_a_timer'}
                 end
                };
            {ok, Transport, Socket} ->
                {ok, State#state{connection = {Transport, Socket}}};
            {error, Error} ->
                ?Error("connect error ~p", [Error]),
                catch erlang:cancel_timer(State#state.unauthIdleTmr),
                {stop, Error}
        end
    catch
        _Class:Reason ->
            ?Error("connect error ~p stackstrace ~p",
                   [Reason, erlang:get_stacktrace()]),
            case Connect of
                {gen_tcp, Sock} -> gen_tcp:close(Sock);
                {ssl, Sock} -> ssl:close(Sock);
                _ -> ok
            end,
            {stop, Reason}
    end.

-spec connect(local | local_sec
              | {tcp, inet:ip_address() | inet:hostname(), inet:port_number()}
              | {tcp, inet:ip_address() | inet:hostname(), inet:port_number(),
                 Opts::list()}) ->
    ok
    | {ok, ssl, ssl:sslsocket()} | {ok, gen_tcp, gen_tcp:socket()}
    | {error, term()}.
connect({tcp, IpAddr, Port}) -> connect({tcp, IpAddr, Port, []});
connect({tcp, IpAddr, Port, Opts}) ->
    {TcpMod, InetMod} = case lists:member(ssl, Opts) of
                            true -> {ssl, ssl};
                            _ -> {gen_tcp, inet}
                        end,
    {ok, Ip} = inet:getaddr(IpAddr, inet),
    ?Debug("connecting to ~p:~p ~p", [Ip, Port, Opts]),
    case TcpMod:connect(Ip, Port, [], ?CONNECT_TIMEOUT) of
        {ok, Socket} ->
            case InetMod:setopts(Socket, [{active, true}, binary, {packet, 4}, {nodelay, true}]) of
                ok ->
                    {ok, case lists:member(ssl, Opts) of
                             true -> ssl;
                             _ -> gen_tcp
                         end,
                     Socket};
                {error, Error} -> {error, Error}
            end;
        {error, Error} -> {error, Error}
    end;
connect(local_sec)                          -> ok;
connect(local)                              -> ok.

%% handle_call overloads
%%
handle_call({auth, AppId, SessionId, Credentials}, From,
            #state{seco = '$not_a_session', authorized = false} = State) ->
    handle_call([auth_start, AppId, SessionId, Credentials], From, State);
handle_call({auth, _AppId, _SessionId, Credentials}, From,
            #state{authorized = false} = State) ->
    catch erlang:cancel_timer(State#state.unauthIdleTmr),
    handle_call([auth_add_cred, Credentials], From,
                State#state{unauthIdleTmr
                            = erlang:send_after(?UNAUTHIDLETIMEOUT, self(),
                                                unauthorized)});
handle_call({skey, SKey, Authorized}, _From, #state{authorized = false} = State) ->
    catch erlang:cancel_timer(State#state.unauthIdleTmr),
    {reply, ok, State#state{
                  seco = case State#state.seco of % SKey can be set only once
                             '$not_a_session' -> SKey;
                             _ -> State#state.seco
                         end,
                  unauthIdleTmr = if Authorized -> '$not_a_timer';
                                     true ->
                                         erlang:send_after(
                                           ?UNAUTHIDLETIMEOUT, self(),
                                           unauthorized)
                                  end,
                  authorized = Authorized}};
handle_call(get_stmts, _From, #state{stmts=Stmts} = State) ->
    {reply,[S|| {S,_} <- Stmts],State};
handle_call(stop, _From, State) ->
    {stop,normal, ok, State};
handle_call({add_stmt_fsm, StmtRef, {_, _, StmtFsmPid} = StmtFsm}, _From, #state{stmts=Stmts} = State) ->
    erlang:monitor(process, StmtFsmPid),
    NStmts = lists:keystore(StmtRef, 1, Stmts, {StmtRef, #stmt{fsm = StmtFsm}}),
    {reply,ok,State#state{stmts=NStmts}};
handle_call({add_stmt_fsm, StmtRef, {_, StmtFsmPid} = StmtFsm}, _From, #state{stmts=Stmts} = State) ->
    erlang:monitor(process, StmtFsmPid),
    NStmts = lists:keystore(StmtRef, 1, Stmts, {StmtRef, #stmt{fsm = StmtFsm}}),
    {reply,ok,State#state{stmts=NStmts}};
handle_call({check_schema, Schema, SKey}, _From, #state{schema = StSchema} = State) ->
    StSchemaAtom =
    if is_binary(StSchema) ->
            case catch binary_to_existing_atom(StSchema, utf8) of
                StSchemaA when is_atom(StSchemaA) -> StSchemaA;
                _ -> {}
            end;
       is_atom(StSchema) -> StSchema;
       true -> StSchema
    end,
    if Schema == StSchemaAtom -> {reply, SKey, State#state{schema = Schema}};
       true -> {stop, shutdown, {error, <<"Not a valid schema">>}, State}
    end;
handle_call(Msg, From, #state{connection=Connection
                             ,schema=Schema
                             ,seco=SeCo
                             ,event_pids=EvtPids} = State) ->
    % blocking command entry, responded later in handle_info
    [Cmd|Rest] = Msg,
    NewMsg = case Cmd of
        exec ->
            NewEvtPids = EvtPids,
            [Params|Args] = Rest,
            list_to_tuple([Cmd,SeCo|Args] ++ [[{schema, Schema}, {params, Params}]]);
        subscribe ->
            [Evt|_] = Rest,
            {Pid, _} = From,
            NewEvtPids = lists:keystore(Evt, 1, EvtPids, {Evt, Pid}),
            list_to_tuple([Cmd,SeCo|Rest]);
        _ ->
            NewEvtPids = EvtPids,
            list_to_tuple([Cmd,SeCo|Rest])
    end,
    ?Debug("call ~p", [NewMsg]),
    case (catch exec_cmd(From, NewMsg, Connection)) of
        {'EXIT', E} ->
            ?Error("cmd ~p error~n~p~n", [Cmd, E]),
            {reply, E, State#state{event_pids=NewEvtPids}};
        {{error, E}, ST} ->
            ?Error("cmd ~p error~n~p~n", [Cmd, E]),
            ?Debug("~p", [ST]),
            {reply, E, State#state{event_pids=NewEvtPids}};
        Result ->
            if Result /= ok -> ?Warn("Unexpected result ~p", [Result]);
               true -> ok
            end,
            {noreply,State#state{event_pids=NewEvtPids}}
    end.


%% handle_cast overloads
%%  unhandled
handle_cast(Request, State) ->
    ?Error([session, self()], "unknown cast ~p", [Request]),
    {stop,cast_not_supported,State}.

%% handle_info overloads
%%
handle_info(unauthorized, State) ->
    case State#state.authorized of
        false ->
            ?Error("Session authorization timeout"),
            {stop,normal,State};
        true ->
            ?Info("Session already authorized"),
            {noreply, State#state{unauthIdleTmr = '$not_a_timer'}}
    end;
handle_info(timeout, State) ->
    ?Info("~p close on timeout", [self()]),
    {stop,normal,State};

% tcp
%handle_info({Tcp, S, <<L:32, PayLoad/binary>> = Pkt}, #state{buf={0, <<>>}, inetmod=InetMod} = State) when Tcp =:= tcp; Tcp =:= ssl ->
%    ?Debug("RX (~p)~n~p", [byte_size(Pkt),Pkt]),
%    InetMod:setopts(S,[{active,once}]),
%    ?Debug( " term size ~p~n", [L]),
%    {NewLen, NewBin, Commands} = split_packages(L, PayLoad),
%    NewState = process_commands(Commands, State),
%    {noreply, NewState#state{buf={NewLen, NewBin}}};
handle_info({Tcp, _Sock, Command}, State) when Tcp =:= tcp; Tcp =:= ssl ->
    ?Debug("RX (~p)~n~p", [byte_size(Command), Command]),
    NewState = case (catch binary_to_term(Command)) of
        {'EXIT', Reason} ->
            ?Error("[MALFORMED] RX ~p byte of term, ignoring command : ~p~n~p",
                   [byte_size(Command), Reason, Command]),
            State;
        {From, {error, Exception}} ->
            ?Error("to ~p throw~n~p~n", [From, Exception]),
            gen_server:reply(From,  {error, Exception}),
            State;
        {From, Term} ->
            ?Debug("TCP async __RX__ ~p For ~p", [Term, From]),
            {noreply, ResultState} = handle_info({From,Term}, State),
            ResultState
    end,
    {noreply, NewState};
handle_info({Closed,Socket}, State) when Closed =:= tcp_closed; Closed =:= ssl_closed ->
    ?Info("~p ~p ~p", [self(), Closed, Socket]),
    {stop,normal,State};

% statement monitor events
handle_info({'DOWN', Ref, process, StmtFsmPid, Reason}, #state{stmts=Stmts}=State) ->
    [StmtRef|_] = [SR || {SR, DS} <- Stmts, element(2, DS#stmt.fsm) =:= StmtFsmPid],
    NewStmts = lists:keydelete(StmtRef, 1, Stmts),
    true = demonitor(Ref, [flush]),
    ?Debug("FSM ~p died with reason ~p for stmt ~p remaining ~p", [StmtFsmPid, Reason, StmtRef, [S || {S,_} <- NewStmts]]),
    {noreply, State#state{stmts=NewStmts}};

% mnesia events handling
handle_info({_,{complete, _}} = Evt, #state{event_pids=EvtPids}=State) ->
    case lists:keyfind(activity, 1, EvtPids) of
        {_, Pid} when is_pid(Pid) -> Pid ! Evt;
        Found ->
            ?Debug([session, self()], "# ~p <- ~p", [Found, Evt])
    end,
    {noreply, State};
handle_info({_,{S, Ctx, _}} = Evt, #state{event_pids=EvtPids}=State) when S =:= write;
                                                                          S =:= delete_object;
                                                                          S =:= delete ->
    Tab = element(1, Ctx),
    case lists:keyfind({table, Tab}, 1, EvtPids) of
        {_, Pid} -> Pid ! Evt;
        _ ->
            case lists:keyfind({table, Tab, simple}, 1, EvtPids) of
                {_, Pid} when is_pid(Pid) -> Pid ! Evt;
                Found ->
                    ?Debug([session, self()], "# ~p <- ~p", [Found, Evt])
            end
    end,
    {noreply, State};
handle_info({_,{D,Tab,_,_,_}} = Evt, #state{event_pids=EvtPids}=State) when D =:= write;
                                                                            D =:= delete ->
    case lists:keyfind({table, Tab, detailed}, 1, EvtPids) of
        {_, Pid} when is_pid(Pid) -> Pid ! Evt;
        Found ->
            ?Debug([session, self()], "# ~p <- ~p", [Found, Evt])
    end,
    {noreply, State};

% local / tcp fallback
handle_info({_Ref,{StmtRef,Result}}, #state{stmts=Stmts}=State) when is_pid(StmtRef) ->
    case lists:keyfind(StmtRef, 1, Stmts) of
        {_, #stmt{fsm=StmtFsm}} ->
            case Result of
                {error, Resp} = Error ->
                    StmtFsm:rows({StmtRef,Error}),
                    ?Error([session, self()], "async_resp~n~p~n", [Resp]),
                    {noreply, State};
                {delete, {Rows, Completed}} when is_list(Rows) ->
                    StmtFsm:delete({StmtRef,{Rows, Completed}}),
                    ?Debug("~p __RX__ deleted rows ~p status ~p", [StmtRef, length(Rows), Completed]),
                    {noreply, State};
                {Rows, Completed} when is_list(Rows) ->
                    StmtFsm:rows({StmtRef,{Rows,Completed}}),
                    ?Debug("~p __RX__ received rows ~p status ~p", [StmtRef, length(Rows), Completed]),
                    {noreply, State};
                Unknown ->
                    StmtFsm:rows({StmtRef,Unknown}),
                    ?Error([session, self()], "async_resp unknown resp~n~p~n", [Unknown]),
                    {noreply, State}
            end;
        false ->
            ?Error("statement ~p not found in ~p", [StmtRef, [S|| {S,_} <- Stmts]]),
            {noreply, State}
    end;
handle_info({{P,_}, {imem_async, Resp}}, State) when is_pid(P) ->
    ?Debug("Async __RX__ ~p For ~p", [Resp, P]),
    P ! Resp,
    {noreply, State};
handle_info({{P, _} = From, Resp}, #state{stmts=Stmts}=State) when is_pid(P) ->
    % blocking command response after async reply from command stub comes in
    case Resp of
        {error, Exception} ->
            ?Debug("to ~p throw~n~p~n", [From, Exception]),
            gen_server:reply(From,  {error, Exception}),
            {noreply, State};
        {ok, #stmtResults{stmtRefs=StmtRefs} = SRslt} ->
            ?Debug("RX ~p", [SRslt]),
            %Rslt = {ok, SRslt, {?MODULE, StmtRef, self()}},
            Rslt = {ok, SRslt},
            ?Debug("statement ~p stored in ~p", [StmtRefs, [S|| {S,_} <- Stmts]]),
            gen_server:reply(From, Rslt),
            {noreply, State#state{stmts=Stmts}};
        Resp ->
            ?Debug("Sync __RX__ ~p For ~p", [Resp, From]),
            gen_server:reply(From, Resp),
            {noreply, State}
    end;
handle_info(Info, State) ->
    ?Error([session, self()], "unknown info ~p", [Info]),
    {noreply, State}.

terminate(Reason, #state{connection = Connect} = State) ->
    try
        _ = [StmtFsm:stop() || #stmt{fsm=StmtFsm} <- State#state.stmts],
        if State#state.authorized ->
               exec_cmd(undefined, {logout, State#state.seco}, Connect);
           true -> ok
        end,
        case Connect of
            {_, Transport, Socket} -> Transport:close(Socket);
            _ -> ok
        end        
    catch
        _:Exception -> ?Error("Cleanup error ~p: ~p",
                              [Exception, erlang:get_stacktrace()])
    end,
    ?Debug("stopped ~p config ~p for ~p", [self(), Connect, Reason]).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%
% private functions
%

-spec exec_cmd(undefined | pid(), tuple(), atom() | {atom(), term()}) -> ok | {error, atom()}.
exec_cmd(Ref, CmdTuple, local_sec) ->
    safe_exec_cmd(Ref, local_sec, imem_sec, CmdTuple);
exec_cmd(Ref, CmdTuple, local) ->
    {[Cmd|_], Args} = lists:split(1, tuple_to_list(CmdTuple)),
    safe_exec_cmd(Ref, local, imem_meta, list_to_tuple([Cmd|lists:nthtail(1, Args)]));
exec_cmd(Ref, CmdTuple, {gen_tcp, Socket}) ->
    safe_exec_cmd(Ref, {gen_tcp, Socket}, imem_sec, CmdTuple);
exec_cmd(Ref, CmdTuple, {ssl, Socket}) ->
    safe_exec_cmd(Ref, {ssl, Socket}, imem_sec, CmdTuple).

-spec safe_exec_cmd(undefined | pid(), local | local_sec |
                 {gen_tcp, gen_tcp:socket()}
                 | {ssl, ssl:sslsocket()},
                 imem_sec | imem_meta,
                 tuple()) -> ok | {error, atom()}.
safe_exec_cmd(Ref, Media, Mod, CmdTuple) ->
    {Cmd, Args0} = lists:split(1, tuple_to_list(CmdTuple)),
    Fun = lists:nth(1, Cmd),

    Args = case Fun of
        fetch_recs_async -> Args0 ++ [self()];
        _                -> Args0
    end,
    try
        case Media of
            Media when Media == local; Media == local_sec ->
                ?Debug([session, self()], "~p MFA ~p", [?MODULE, {Mod, Fun, Args}]),
                ok = apply(imem_server, mfa, [{Ref, Mod, Fun, Args}, {self(), Ref}]);
            {Transport, Socket} ->
                ?Debug([session, self()], "TCP ___TX___ ~p", [{Mod, Fun, Args}]),
                ReqBin = term_to_binary({Ref,Mod,Fun,Args}),
                Transport:send(Socket, ReqBin)
        end
    catch
        _Class:Result ->
            throw({{error, Result}, erlang:get_stacktrace()})
    end.
