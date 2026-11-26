-module(relay_ffi).
-export([
    is_null/1,
    dynamic_to_json_string/1,
    raw_json/1,
    decode_json_exact/1,
    exact_to_value/2,
    exact_to_native/1,
    unique_integer/0,
    rescue_run/1,
    monotonic_time_ms/0,
    reserve_stdio/0,
    read_stdin/0,
    lead_output_to_stderr/0,
    restore_group_leader/1,
    stop_supervisor/1,
    child_environment/3,
    write_stdout/1,
    write_stderr/1,
    spawn_stdio_child/1,
    spawn_stdio_child_closed_stdout/1,
    send_to_child/2,
    receive_from_child/2,
    receive_exit_status/2,
    close_child/1,
    mailbox_size/1,
    process_alive/1,
    new_cursor_key/0,
    make_cursor/3,
    read_cursor/3,
    sha256_hex/1,
    read_file/1,
    git_head/1,
    watch_client_close/1,
    set_send_timeout/2,
    decode_base64_strict/1,
    start_stdio_client_port/4,
    send_stdio_client_command/2,
    close_stdio_client_port/1,
    json_depth_within/2,
    signal_cancelled/2,
    hold/1,
    held_get/1,
    release/1
]).

%% Sets the send timeout of a mist connection's socket, so a peer that stops
%% reading cannot block a stream writer forever.
set_send_timeout({connection, _Body, Socket, Transport, _Factory}, Timeout) ->
    Options = [{send_timeout, Timeout}, {send_timeout_close, true}],
    Result = case Transport of
        tcp -> inet:setopts(Socket, Options);
        ssl -> ssl:setopts(Socket, Options)
    end,
    case Result of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end;
set_send_timeout(_, _) ->
    {error, nil}.

%% Arms one closure message ({tcp_closed, S}, {ssl_closed, S}, or an error
%% tuple) for the connection process that runs a buffered HTTP handler. Data
%% that arrives instead stays in the mailbox for mist's own loop.
watch_client_close({connection, _Body, Socket, Transport, _Factory}) ->
    Result = case Transport of
        tcp -> inet:setopts(Socket, [{active, once}]);
        ssl -> ssl:setopts(Socket, [{active, once}])
    end,
    case Result of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end;
watch_client_close(_) ->
    {error, nil}.

decode_base64_strict(Encoded) when is_binary(Encoded) ->
    try
        Decoded = base64:decode(Encoded),
        case {base64:encode(Decoded) =:= Encoded,
              unicode:characters_to_binary(Decoded, utf8, utf8)} of
            {true, Utf8} when is_binary(Utf8) -> {ok, Utf8};
            _ -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

is_null(null) -> true;
is_null(nil) -> true;
is_null(_) -> false.

raw_json(Bin) when is_binary(Bin) -> Bin;
raw_json(List) when is_list(List) -> list_to_binary(List).

dynamic_to_json_string(Data) ->
    try
        iolist_to_binary(json:encode(Data))
    catch
        _:_ -> <<"{}"/utf8>>
    end.

%% Parses one JSON value and nothing after it but whitespace, keeping every
%% number as its source text in a `{raw_number, Text}` tuple. Returns
%% `{ok, Term}` or `{error, nil}`.
decode_json_exact(Bin) ->
    Decoders = #{
        float => fun(B) -> {raw_number, B} end,
        integer => fun(B) -> {raw_number, B} end
    },
    try
        {Root, ok, Rest} = json:decode(Bin, ok, Decoders),
        case is_json_whitespace(Rest) of
            true -> {ok, Root};
            false -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

is_json_whitespace(<<>>) -> true;
is_json_whitespace(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    is_json_whitespace(Rest);
is_json_whitespace(_) -> false.

%% A term from `decode_json_exact` with its numbers as integers and floats.
exact_to_native({raw_number, Text}) ->
    {Number, ok, _} = json:decode(Text, ok, #{}),
    Number;
exact_to_native(Map) when is_map(Map) ->
    maps:map(fun(_Key, Value) -> exact_to_native(Value) end, Map);
exact_to_native(List) when is_list(List) ->
    [exact_to_native(Item) || Item <- List];
exact_to_native(Other) ->
    Other.

%% A term from `decode_json_exact` as a JSON Blueprint value, its numbers
%% parsed within `Limits`.
exact_to_value(Term, Limits) ->
    term_to_blueprint_value(Term, Limits).

term_to_blueprint_value(null, _Limits) -> {ok, null};
term_to_blueprint_value(true, _Limits) -> {ok, {bool, true}};
term_to_blueprint_value(false, _Limits) -> {ok, {bool, false}};
term_to_blueprint_value(Bin, _Limits) when is_binary(Bin) -> {ok, {string, Bin}};
term_to_blueprint_value({raw_number, NumBin}, Limits) ->
    case json@blueprint@number:parse(NumBin, Limits) of
        {ok, Num} -> {ok, {number, Num}};
        {error, _} -> {error, nil}
    end;
term_to_blueprint_value(List, Limits) when is_list(List) ->
    case lists:foldr(fun(Elem, {ok, Acc}) ->
                         case term_to_blueprint_value(Elem, Limits) of
                             {ok, V} -> {ok, [V | Acc]};
                             _ -> error
                         end;
                        (_, error) -> error
                     end, {ok, []}, List) of
        {ok, Items} -> {ok, {array, Items}};
        error -> {error, nil}
    end;
term_to_blueprint_value(Map, Limits) when is_map(Map) ->
    case lists:foldr(fun({K, V}, {ok, Acc}) ->
                         case term_to_blueprint_value(V, Limits) of
                             {ok, Val} -> {ok, [{K, Val} | Acc]};
                             _ -> error
                         end;
                        (_, error) -> error
                     end, {ok, []}, maps:to_list(Map)) of
        {ok, Entries} -> {ok, {object, Entries}};
        error -> {error, nil}
    end;
term_to_blueprint_value(_, _) -> {error, nil}.

unique_integer() ->
    erlang:unique_integer([positive, monotonic]).

new_cursor_key() ->
    crypto:strong_rand_bytes(32).

make_cursor(Key, Family, Offset)
  when is_binary(Key), is_binary(Family), is_integer(Offset),
       Offset >= 0, Offset =< 16#FFFFFFFFFFFFFFFF,
       byte_size(Family) =< 65535 ->
    Payload = <<Offset:64/unsigned-big, (byte_size(Family)):16/unsigned-big,
                Family/binary>>,
    Mac = binary:part(crypto:mac(hmac, sha256, Key, Payload), 0, 16),
    base64url_encode(<<Payload/binary, Mac/binary>>).

read_cursor(Key, Family, Token)
  when is_binary(Key), is_binary(Family), is_binary(Token) ->
    try
        Decoded = base64url_decode(Token),
        case Decoded of
            <<Offset:64/unsigned-big, FamilySize:16/unsigned-big, Rest/binary>>
              when byte_size(Rest) =:= FamilySize + 16,
                   Offset =< 1000000000 ->
                <<EncodedFamily:FamilySize/binary, Mac:16/binary>> = Rest,
                PayloadSize = 10 + FamilySize,
                <<Payload:PayloadSize/binary, _/binary>> = Decoded,
                ExpectedMac = binary:part(crypto:mac(hmac, sha256, Key, Payload), 0, 16),
                case EncodedFamily =:= Family andalso Mac =:= ExpectedMac of
                    true -> {ok, Offset};
                    false -> {error, nil}
                end;
            _ -> {error, nil}
        end
    catch
        _:_ -> {error, nil}
    end.

base64url_encode(Data) ->
    Encoded = base64:encode(Data),
    NoPadding = binary:replace(Encoded, <<"=">>, <<>>, [global]),
    PlusSafe = binary:replace(NoPadding, <<"+">>, <<"-">>, [global]),
    binary:replace(PlusSafe, <<"/">>, <<"_">>, [global]).

base64url_decode(Token) ->
    PlusRestored = binary:replace(Token, <<"-">>, <<"+">>, [global]),
    SlashRestored = binary:replace(PlusRestored, <<"_">>, <<"/">>, [global]),
    PaddingSize = (4 - (byte_size(SlashRestored) rem 4)) rem 4,
    Padding = binary:copy(<<"=">>, PaddingSize),
    base64:decode(<<SlashRestored/binary, Padding/binary>>).

monotonic_time_ms() ->
    erlang:monotonic_time(millisecond).

rescue_run(Fun) ->
    try
        {ok, Fun()}
    catch
        _Class:_Reason:_Stack ->
            {error, <<"handler crashed (redacted)">>}
    end.

%% Prepares the VM for serving MCP over its standard streams. Standard input
%% is Relay's only when the VM never reads it itself, which `-noinput`
%% guarantees; otherwise the VM's terminal reader already owns descriptor 0.
%% Every logger handler that writes to standard output is moved to standard
%% error, so that log events (crash reports and emulator warnings included)
%% cannot interleave with protocol frames.
reserve_stdio() ->
    case init:get_argument(noinput) of
        error -> {error, nil};
        {ok, _} ->
            lists:foreach(fun route_handler_to_stderr/1, logger:get_handler_config()),
            {ok, nil}
    end.

%% `logger_std_h` cannot change its `type` in place, so the handler is
%% removed and added again with the same level, filters, formatter and
%% overload settings.
route_handler_to_stderr(#{id := Id, module := logger_std_h,
                          config := #{type := standard_io} = Config} = Handler) ->
    Overload = maps:with([sync_mode_qlen, drop_mode_qlen, flush_qlen,
                          burst_limit_enable, burst_limit_max_count,
                          burst_limit_window_time, overload_kill_enable,
                          overload_kill_qlen, overload_kill_mem_size,
                          overload_kill_restart_after], Config),
    Kept = maps:with([level, filter_default, filters, formatter], Handler),
    _ = logger:remove_handler(Id),
    _ = logger:add_handler(Id, logger_std_h,
                           Kept#{config => Overload#{type => standard_error}}),
    ok;
route_handler_to_stderr(_) ->
    ok.

%% Makes standard error the group leader of the calling process and returns
%% the previous one. Processes it spawns from now on inherit the new group
%% leader, so `io` output from the runtime and its handlers goes to standard
%% error instead of standard output.
lead_output_to_stderr() ->
    Previous = group_leader(),
    case whereis(standard_error) of
        undefined -> ok;
        StandardError -> group_leader(StandardError, self())
    end,
    Previous.

restore_group_leader(Previous) ->
    group_leader(Previous, self()),
    nil.

%% Returns the next bytes of standard input as soon as any arrive. A raw file
%% read of a pipe waits for its whole count, so input comes from a port in
%% stream mode on descriptor 0, owned by the calling process. The port
%% delivers each read as it completes, so the framer bounds a frame while it
%% grows. A port cannot be paused: input the server has not framed yet waits
%% in the owner's mailbox.
read_stdin() ->
    case ensure_stdin_port() of
        {ok, Port} ->
            receive
                {Port, {data, Data}} -> {read_chunk, Data};
                {Port, eof} -> read_eof
            end;
        {error, Reason} ->
            {read_failed, printable(Reason)}
    end.

ensure_stdin_port() ->
    case get(relay_stdio_input) of
        undefined ->
            try erlang:open_port({fd, 0, 1}, [in, binary, stream, eof]) of
                Port ->
                    put(relay_stdio_input, Port),
                    {ok, Port}
            catch
                error:Reason -> {error, Reason}
            end;
        Port ->
            {ok, Port}
    end.

mailbox_size(Pid) when is_pid(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, N} -> N;
        _ -> 0
    end;
mailbox_size(_) -> 0.

process_alive(Pid) when is_pid(Pid) ->
    erlang:is_process_alive(Pid);
process_alive(_) -> false.

write_stdout(Bin) ->
    case ensure_stdout_output() of
        {ok, Device} ->
            case file:write(Device, Bin) of
                ok -> {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

ensure_stdout_output() ->
    case get(relay_stdio_output) of
        undefined ->
            case file:open("/dev/stdout", [write, binary, raw]) of
                {ok, Device} ->
                    put(relay_stdio_output, Device),
                    {ok, Device};
                {error, Reason} -> {error, Reason}
            end;
        Device -> {ok, Device}
    end.

write_stderr(Bin) ->
    case io:put_chars(standard_error, Bin) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

spawn_stdio_child(Cmd) ->
    Port = erlang:open_port(
        {spawn, binary_to_list(Cmd)},
        [stream, binary, use_stdio, exit_status]
    ),
    Port.

spawn_stdio_child_closed_stdout(Cmd) ->
    Python = os:find_executable("python3"),
    Script = lists:flatten([
        "import select, subprocess, sys\n",
        "child = subprocess.Popen(sys.argv[1], shell=True, stdin=subprocess.PIPE, ",
        "stdout=subprocess.PIPE, bufsize=0)\n",
        "child.stdout.close()\n",
        "request = sys.stdin.buffer.readline()\n",
        "child.stdin.write(request)\n",
        "child.stdin.flush()\n",
        "while child.poll() is None:\n",
        "    ready, _, _ = select.select([sys.stdin.buffer], [], [], 0.05)\n",
        "    if ready:\n",
        "        sys.stdin.buffer.readline()\n",
        "        child.stdin.close()\n",
        "        break\n",
        "sys.exit(child.wait())\n"
    ]),
    erlang:open_port(
        {spawn_executable, Python},
        [stream, binary, use_stdio, exit_status, {args, ["-u", "-c", Script, binary_to_list(Cmd)]}]
    ).

send_to_child(Port, Bytes) ->
    Port ! {self(), {command, Bytes}},
    ok.

receive_from_child(Port, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            {ok, Data}
    after TimeoutMs ->
        {error, timeout}
    end.

receive_exit_status(Port, TimeoutMs) ->
    receive
        {Port, {exit_status, Status}} -> {ok, Status}
    after TimeoutMs ->
        {error, timeout}
    end.

close_child(Port) ->
    try erlang:port_close(Port) catch _:_ -> ok end,
    ok.

sha256_hex(Bytes) ->
    Hash = crypto:hash(sha256, Bytes),
    string:lowercase(binary:encode_hex(Hash)).

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

git_head(RepoPath) ->
    Cmd = "git -C " ++ binary_to_list(RepoPath) ++ " rev-parse HEAD",
    Out = os:cmd(Cmd),
    string:trim(unicode:characters_to_binary(Out)).

%% Stops a listener's supervision tree and returns once its sockets are
%% closed. `sys:terminate` replies before the supervisor shuts its children
%% down, and a port owned by an exited process closes after the owner's
%% exit, so the wait is on the supervisor's exit and then on each socket.
%% The tree's shutdown timeouts bound both waits.
stop_supervisor(Pid) when is_pid(Pid) ->
    Sockets = [erlang:monitor(port, Port) || Port <- sockets_under(Pid)],
    Ref = erlang:monitor(process, Pid),
    try sys:terminate(Pid, shutdown, infinity) catch _:_ -> ok end,
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    [receive {'DOWN', Socket, port, _, _} -> ok end || Socket <- Sockets],
    nil.

%% TCP sockets, listening or accepted, owned by a process started under
%% `Supervisor`. Reads each owner's `proc_lib` ancestry instead of asking
%% the supervisors, so a busy or suspended supervisor cannot delay it.
sockets_under(Supervisor) ->
    [Port || Port <- erlang:ports(),
             erlang:port_info(Port, name) =:= {name, "tcp_inet"},
             {connected, Owner} <- [erlang:port_info(Port, connected)],
             lists:member(Supervisor, ancestors(Owner))].

ancestors(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            proplists:get_value('$ancestors', Dictionary, []);
        undefined ->
            []
    end.

%% The environment of a stdio child: the variables a program needs to run
%% (the same allow-list the reference MCP SDKs use), inherited from this OS
%% process, plus the ones the caller added. A port inherits the whole
%% environment unless each other variable is unset, so the rest are unset.
child_environment(Added) ->
    child_environment(os:type(), os:env(), Added).

child_environment(OsType, Inherited, Added) ->
    Allowed = case OsType of
        {win32, _} ->
            ["APPDATA", "HOMEDRIVE", "HOMEPATH", "LOCALAPPDATA", "PATH",
             "PROCESSOR_ARCHITECTURE", "SYSTEMDRIVE", "SYSTEMROOT", "TEMP",
             "USERNAME", "USERPROFILE", "PROGRAMFILES"];
        _ ->
            ["HOME", "LOGNAME", "PATH", "SHELL", "TERM", "USER"]
    end,
    %% Windows variable names ignore case and keep the spelling they were
    %% set with; Unix names are compared exactly.
    Key = case OsType of
        {win32, _} -> fun string:uppercase/1;
        _ -> fun(Name) -> Name end
    end,
    Explicit = [{unicode:characters_to_list(Name), unicode:characters_to_list(Value)}
                || {Name, Value} <- Added],
    Kept = [Key(Name) || Name <- Allowed ++ [Name || {Name, _} <- Explicit]],
    Unset = [{Name, false} || {Name, _} <- Inherited,
                              not lists:member(Key(Name), Kept)],
    Unset ++ Explicit.

start_stdio_client_port(CmdBin, ArgsList, Added, GleamSubject) ->
    Parent = self(),
    OpenRef = make_ref(),
    Cmd = binary_to_list(CmdBin),
    Args = [binary_to_list(A) || A <- ArgsList],
    Env = child_environment(Added),
    case resolve_stdio_executable(Cmd) of
        {error, Reason} -> {error, Reason};
        {ok, Executable} ->
            {Pid, Monitor} = spawn_monitor(fun() ->
                try erlang:open_port(
                    {spawn_executable, Executable},
                    [stream, binary, use_stdio, exit_status, {args, Args}, {env, Env}]
                ) of
                    Port ->
                        Parent ! {port_ready, OpenRef, {ok, self()}},
                        ParentMon = erlang:monitor(process, Parent),
                        client_port_loop(Port, GleamSubject, ParentMon)
                catch
                    Class:OpenReason ->
                        Parent ! {port_ready, OpenRef,
                                  {error, printable({Class, OpenReason})}}
                end
            end),
            receive
                {port_ready, OpenRef, {ok, Pid}} ->
                    erlang:demonitor(Monitor, [flush]),
                    {ok, Pid};
                {port_ready, OpenRef, {error, Reason}} ->
                    erlang:demonitor(Monitor, [flush]),
                    {error, Reason};
                {'DOWN', Monitor, process, Pid, Reason} ->
                    {error, printable(Reason)}
            after 5000 ->
                exit(Pid, kill),
                {error, <<"stdio child startup timed out">>}
            end
    end.

resolve_stdio_executable(Cmd) ->
    case filename:pathtype(Cmd) of
        absolute ->
            case filelib:is_regular(Cmd) of
                true -> {ok, Cmd};
                false -> {error, <<"stdio executable does not exist">>}
            end;
        relative ->
            case filename:dirname(Cmd) =:= "." of
                false ->
                    case filelib:is_regular(Cmd) of
                        true -> {ok, filename:absname(Cmd)};
                        false -> {error, <<"stdio executable does not exist">>}
                    end;
                true ->
                    case os:find_executable(Cmd) of
                        false -> {error, <<"stdio executable was not found on PATH">>};
                        Executable -> {ok, Executable}
                    end
            end
    end.

client_port_loop(Port, GleamSubject, ParentMon) ->
    receive
        {Port, {data, Data}} ->
            gleam@erlang@process:send(GleamSubject, {client_port_message, {port_data, Data}}),
            client_port_loop(Port, GleamSubject, ParentMon);
        {Port, {exit_status, Status}} ->
            gleam@erlang@process:send(GleamSubject, {client_port_message, {port_exit, Status}});
        {command, Bytes} ->
            Port ! {self(), {command, Bytes}},
            client_port_loop(Port, GleamSubject, ParentMon);
        {'DOWN', ParentMon, process, _, _} ->
            try erlang:port_close(Port) catch _:_ -> ok end,
            ok;
        close ->
            try erlang:port_close(Port) catch _:_ -> ok end,
            ok
    end.

send_stdio_client_command(Pid, Bytes) ->
    Pid ! {command, Bytes},
    ok.

close_stdio_client_port(Pid) ->
    Pid ! close,
    ok.

printable(Bin) when is_binary(Bin) -> Bin;
printable(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).

%% Scans JSON text for object and array nesting deeper than Max, outside
%% strings, before any parsing.
json_depth_within(Bin, Max) when is_binary(Bin) ->
    depth_scan(Bin, 0, Max, false).

depth_scan(<<>>, _Depth, _Max, _InString) -> true;
depth_scan(<<$\\, _, Rest/binary>>, Depth, Max, true) ->
    depth_scan(Rest, Depth, Max, true);
depth_scan(<<$", Rest/binary>>, Depth, Max, InString) ->
    depth_scan(Rest, Depth, Max, not InString);
depth_scan(<<_, Rest/binary>>, Depth, Max, true) ->
    depth_scan(Rest, Depth, Max, true);
depth_scan(<<C, Rest/binary>>, Depth, Max, false) when C =:= ${; C =:= $[ ->
    case Depth + 1 > Max of
        true -> false;
        false -> depth_scan(Rest, Depth + 1, Max, false)
    end;
depth_scan(<<C, Rest/binary>>, Depth, Max, false) when C =:= $}; C =:= $] ->
    depth_scan(Rest, Depth - 1, Max, false);
depth_scan(<<_, Rest/binary>>, Depth, Max, false) ->
    depth_scan(Rest, Depth, Max, false).

%% Tells a running invocation's worker that it was cancelled.
signal_cancelled(Pid, InvocationId) ->
    Pid ! {relay_invocation_cancelled, InvocationId},
    nil.

%% A value held once in node-wide shared storage (persistent_term), so
%% processes that read it share it instead of copying it: a held term is not
%% copied by spawn or send. A keeper erases it on `release/1` or when the
%% holding process exits. A put of a new key copies the value and the term
%% table; an erase makes every process on the node check its heap for the
%% value, so holders erase only on rare changes and at shutdown.
hold(Value) ->
    Key = {relay_held, make_ref()},
    Owner = self(),
    %% The keeper exists before the value is published, so a holder that
    %% dies at any point after the put still gets its value erased: a monitor
    %% on a holder that already died reports DOWN at once. The keeper's
    %% closure captures the key, never the value.
    Keeper = spawn(fun() ->
        Monitor = erlang:monitor(process, Owner),
        receive
            {'DOWN', Monitor, process, _, _} -> ok;
            {release, Key} -> ok
        end,
        persistent_term:erase(Key)
    end),
    persistent_term:put(Key, Value),
    {Key, Keeper}.

held_get({Key, _Keeper}) -> persistent_term:get(Key).

release({Key, Keeper}) ->
    Keeper ! {release, Key},
    nil.
