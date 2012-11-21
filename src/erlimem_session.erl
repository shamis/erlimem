-module(erlimem_session).
-behaviour(gen_server).

-include("erlimem.hrl").

-record(state, {
    status=closed,
    port,
    pool,
    session_id,
    statements = [],
    connection = {type, handle},
    conn_param,
    idle_timer,
    schema,
    seco = undefined
}).

-record(statement, {
        buf,
        ref,
        result
    }).

%% API
-export([open/3
        , close/1
        , exec/2
        , exec/3
        , read_block/2
        , run_cmd/3
        , start_async_read/1
        , get_next/3
		]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

%% @doc open new session
open(Type, Opts, Cred) ->
    {ok, Pid} = gen_server:start(?MODULE, [Type, Opts, Cred], []),
    {?MODULE, Pid}.

close({?MODULE, Pid})          -> gen_server:call(Pid, stop);
close({?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {close_statement, StmtRef}).

exec(StmtStr,                                    Ctx) -> exec(StmtStr, 0, Ctx).
exec(StmtStr, BufferSize,                        Ctx) -> run_cmd(exec, [StmtStr, BufferSize], Ctx).
read_block(StmtRef,                              Ctx) -> run_cmd(read_block, [StmtRef], Ctx).
run_cmd(Cmd, Args, {?MODULE, Pid}) when is_list(Args) -> call(Pid, [Cmd|Args]).
start_async_read(            {?MODULE, StmtRef, Pid}) -> gen_server:cast(Pid, {read_block_async, StmtRef}).
get_next(Count, Cols,        {?MODULE, StmtRef, Pid}) -> gen_server:call(Pid, {get_next, StmtRef, Count, Cols}).

call(Pid, Msg) ->
    gen_server:call(Pid, Msg, ?IMEM_TIMEOUT).

init([Type, Opts, {User, Password}]) when is_binary(User), is_binary(Password) ->
    case connect(Type, Opts) of
        {ok, Connect, Schema} ->
            io:format(user, "~p started ~p connected to ~p~n", [?MODULE, self(), {Type, Opts}]),
            Timer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
            case Connect of
                {local, _} ->
                    SeCo = undefined;
                _ ->
                    SeCo = erlimem_cmds:exec({authenticate, undefined, adminSessionId, User, {pwdmd5, Password}}, Connect),
                    SeCo = erlimem_cmds:exec({login,SeCo}, Connect)
            end,
            {ok, #state{connection=Connect, schema=Schema, conn_param={Type, Opts}, idle_timer=Timer, seco=SeCo}};
        {error, Reason} -> {stop, Reason}
    end.

connect(tcp, {IpAddr, Port, Schema}) ->
    {ok, Ip} = inet:getaddr(IpAddr, inet),
    {ok, Socket} = gen_tcp:connect(Ip, Port, []),
    inet:setopts(Socket, [{active, false}, binary, {packet, 0}, {nodelay, true}]),
    {ok, {tcp, Socket}, Schema};
connect(rpc, {Node, Schema}) when Node == node() -> connect(local_sec, {Schema});
connect(rpc, {Node, Schema}) when is_atom(Node)  -> {ok, {rpc, Node}, Schema};
connect(local_sec, {Schema})                     -> {ok, {local_sec, undefined}, Schema};
connect(local, {Schema})                         -> {ok, {local, undefined}, Schema}.

handle_call(stop, _From, #state{statements=Stmts}=State) ->
    _ = [erlimem_buf:delete_buffer(Buf) || #statement{buf=Buf} <- Stmts],
    {stop,normal,State};
handle_call({close_statement, StmtRef}, _From, #state{statements=Stmts}=State) ->
    case lists:keytake(StmtRef, 1, Stmts) of
        {value, {StmtRef, #statement{buf=Buf}}, NewStmts} -> erlimem_buf:delete_buffer(Buf);
        false                                  -> NewStmts = Stmts
    end,
    {reply,ok,State#state{statements=NewStmts}};
handle_call({get_next, Ref, Count, Cols}, _From, #state{idle_timer=Timer,statements=Stmts} = State) ->
    erlang:cancel_timer(Timer),
    {_, Stmt} = lists:keyfind(Ref, 1, Stmts),
    #statement{buf=Buf} = Stmt,
    {Rows, NewBuf} = erlimem_buf:get_next_rows(Buf, Count, Cols),
    NewStmts = lists:keystore(Ref, 1, Stmts, {Ref, Stmt#statement{buf=NewBuf}}),
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Rows,State#state{idle_timer=NewTimer,statements=NewStmts}};
handle_call(Msg, _From, #state{connection=Connection,idle_timer=Timer,statements=Stmts, schema=Schema, seco=SeCo} = State) ->
    erlang:cancel_timer(Timer),
    [Cmd|Rest] = Msg,
    NewMsg = case Cmd of
        exec -> list_to_tuple([Cmd,SeCo|Rest] ++ [Schema]);
        _ -> list_to_tuple([Cmd,SeCo|Rest])
    end,
    NewState = case erlimem_cmds:exec(NewMsg, Connection) of
        {ok, Clms, Ref} ->
            Result = {ok, Clms, {?MODULE, Ref, self()}},
            State#state{statements=lists:keystore(Ref, 1, Stmts,
                            {Ref, #statement{ result={columns, Clms}
                                            , ref=Ref
                                            , buf=erlimem_buf:create_buffer()}
                            })
                       };
        Res ->
            Result = Res,
            State
    end,
    NewTimer = erlang:send_after(?SESSION_TIMEOUT, self(), timeout),
    {reply,Result,NewState#state{idle_timer=NewTimer}}.

handle_cast({read_block_async, StmtRef}, #state{connection=Connection,statements=Stmts, seco=SeCo}=State) ->    
    {_, #statement{buf=Buffer}} = lists:keyfind(StmtRef, 1, Stmts),
    case erlimem_cmds:exec({read_block, SeCo, StmtRef}, Connection) of
        {ok, []} -> {noreply, State};
        {ok, Rows} ->
            erlimem_buf:insert_rows(Buffer, Rows),
            gen_server:cast(self(), {read_block_async, SeCo, StmtRef}),
            {noreply, State}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(timeout, State) ->
    close({?MODULE, self()}),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{conn_param={Type, Opts},idle_timer=Timer}) ->
    erlang:cancel_timer(Timer),
    io:format(user, "stopped ~p ~p disconnected from ~p~n", [?MODULE, self(), {Type, Opts}]).

code_change(_OldVsn, State, _Extra) -> {ok, State}.


% EUnit tests --

-include_lib("eunit/include/eunit.hrl").

setup() -> 
    Schema = "Mnesia",
    User = <<"admin">>,
    Password = erlang:md5(<<"change_on_install">>),
    Cred = {User, Password},
    erlimem:start(),
    erlimem_session:open(tcp, {localhost, 8124, Schema}, Cred).

teardown(_Sess) ->
   % Sess:close(),
   erlimem:stop().

db_test_() ->
    {timeout, 1000000, {
        setup,
        fun setup/0,
        fun teardown/1,
        {with, [
                fun tcp_table_craete_select_drop/1
            ,   fun tcp_table_all_tables/1
        ]}
        }
    }.

tcp_table_craete_select_drop(Sess) ->
    Res = Sess:exec("create table def (col1 int, col2 char);"),
    io:format(user, "Create ~p~n", [Res]),
    {error, Result} = Sess:exec("create table def (col1 int, col2 char);"),
    io:format(user, "Duplicate Create ~p~n", [Result]),
    Res0 = insert_range(Sess, 210, "def"),
    io:format(user, "insert ~p~n", [Res0]),
    {ok, Clms, Statement} = Sess:exec("select * from def;", 100),
    io:format(user, "select ~p~n", [{Clms, Statement}]),
    Statement:start_async_read(),
    timer:sleep(1000),
    io:format(user, "receiving...~n", []),
    Rows = Statement:get_next(100, [{},{}]),
    io:format(user, "received ~p~n", [length(Rows)]),
    ok = Sess:exec("drop table def;"),
    Statement:close(),
    io:format(user, "drop table~n", []).

tcp_table_all_tables(Sess) ->
    {ok, Clms, Statement} = Sess:exec("select * from all_tables;", 100),
    io:format(user, "select ~p~n", [{Clms, Statement}]),
    Statement:start_async_read(),
    timer:sleep(1000),
    io:format(user, "receiving...~n", []),
    Rows = Statement:get_next(100, [{},{}]),
    io:format(user, "received ~p~n", [Rows]).

insert_range(_Sess, 0, _TableName) -> ok;
insert_range(Sess, N, TableName) when is_integer(N), N > 0 ->
    Sess:exec("insert into " ++ TableName ++ " values (" ++ integer_to_list(N) ++ ", '" ++ integer_to_list(N) ++ "');"),
    insert_range(Sess, N-1, TableName).
