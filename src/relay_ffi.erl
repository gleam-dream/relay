-module(relay_ffi).
-export([
    is_null/1,
    dynamic_to_json_string/1,
    raw_json/1,
    extract_arguments_as_blueprint_value/1,
    extract_input_responses_as_blueprint_value/1,
    unique_integer/0,
    rescue_run/1,
    monotonic_time_ms/0,
    set_stdio_binary/0,
    close_stdin/0,
    read_stdin/1,
    stop_supervisor/1,
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
    send_sse_comment/2,
    set_sse_send_timeout/2,
    decode_base64_strict/1,
    start_stdio_client_port/3,
    send_stdio_client_command/2,
    close_stdio_client_port/1
]).

send_sse_comment(Connection, Timeout) ->
    case set_sse_send_timeout(Connection, Timeout) of
        {ok, nil} ->
            {s_s_e_connection,
             {connection, _Body, Socket, Transport, _Factory}} = Connection,
            case glisten@transport:send(Transport, Socket, <<": keepalive\n\n">>) of
                {ok, _} -> {ok, nil};
                {error, _} -> {error, nil}
            end;
        {error, nil} -> {error, nil}
    end.

set_sse_send_timeout(
    {s_s_e_connection, {connection, _Body, Socket, Transport, _Factory}},
  Timeout
) ->
    Options = [{send_timeout, Timeout}, {send_timeout_close, false}],
    Result = case Transport of
        tcp -> inet:setopts(Socket, Options);
        ssl -> ssl:setopts(Socket, Options)
    end,
    case Result of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

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

extract_arguments_as_blueprint_value(RawJsonBin) ->
    Decoders = #{
        float => fun(B) -> {raw_number, B} end,
        integer => fun(B) -> {raw_number, B} end
    },
    try
        {Root, ok, <<>>} = json:decode(RawJsonBin, ok, Decoders),
        Params = maps:get(<<"params">>, Root, #{}),
        case maps:find(<<"arguments">>, Params) of
            {ok, ArgsTerm} ->
                {ok, Limits} = json@blueprint@number:number_limits(1024, 100, 1000),
                case term_to_blueprint_value(ArgsTerm, Limits) of
                    {ok, {object, Entries}} -> {ok, {object, Entries}};
                    _ -> {error, invalid_arguments}
                end;
            error ->
                {ok, {object, []}}
        end
    catch
        _:_ -> {error, parse_error}
    end.

extract_input_responses_as_blueprint_value(RawJsonBin) ->
    Decoders = #{
        float => fun(B) -> {raw_number, B} end,
        integer => fun(B) -> {raw_number, B} end
    },
    try
        {Root, ok, <<>>} = json:decode(RawJsonBin, ok, Decoders),
        Params = maps:get(<<"params">>, Root, #{}),
        case maps:find(<<"inputResponses">>, Params) of
            {ok, Responses} when is_map(Responses) ->
                {ok, Limits} = json@blueprint@number:number_limits(1024, 100, 1000),
                term_to_blueprint_value(Responses, Limits);
            _ -> {error, invalid_input_responses}
        end
    catch
        _:_ -> {error, parse_error}
    end.

term_to_blueprint_value(null, _Limits) -> {ok, null};
term_to_blueprint_value(true, _Limits) -> {ok, {bool, true}};
term_to_blueprint_value(false, _Limits) -> {ok, {bool, false}};
term_to_blueprint_value(Bin, _Limits) when is_binary(Bin) -> {ok, {string, Bin}};
term_to_blueprint_value({raw_number, NumBin}, Limits) ->
    case json@blueprint@number:parse_number(Limits, NumBin) of
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

set_stdio_binary() ->
    io:setopts(standard_io, [{binary, true}, {encoding, utf8}]),
    io:setopts(standard_error, [{binary, true}, {encoding, utf8}]),
    enable_raw_stdin(),
    {ok, nil}.

close_stdin() ->
    case erase(relay_stdio_input) of
        undefined -> ok;
        Device -> file:close(Device)
    end,
    nil.

enable_raw_stdin() ->
    try
        case whereis(user) of
            undefined -> ok;
            User ->
                case sys:get_status(User) of
                    {status, _, _, [_, _, _, _, [_, _, {data, [{_, {_, State}}]}]]} ->
                        Drv = element(3, State),
                        User ! {Drv, terminal_mode, raw},
                        ok;
                    _ -> ok
                end
        end
    catch
        _:_ -> ok
    end.

read_stdin(ChunkSize) when ChunkSize =< 0 ->
    {read_failed, <<"stdin chunk limit must be positive">>};
read_stdin(ChunkSize) ->
    case ensure_stdin_input() of
        {ok, Device} ->
            read_stdin_result(ChunkSize, file:read(Device, ChunkSize));
        {error, Reason} ->
            {read_failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

ensure_stdin_input() ->
    case get(relay_stdio_input) of
        undefined ->
            case file:open("/dev/stdin", [read, binary, raw]) of
                {ok, Device} ->
                    put(relay_stdio_input, Device),
                    {ok, Device};
                {error, Reason} -> {error, Reason}
            end;
        Device -> {ok, Device}
    end.

read_stdin_result(ChunkSize, {ok, Data}) when is_binary(Data), byte_size(Data) =< ChunkSize ->
    {read_chunk, Data};
read_stdin_result(_ChunkSize, eof) ->
    read_eof;
read_stdin_result(_ChunkSize, {error, Reason}) ->
    {read_failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))};
read_stdin_result(_ChunkSize, _) ->
    {read_failed, <<"stdin returned an invalid chunk">>}.

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
    catch erlang:port_close(Port),
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

stop_supervisor(Pid) when is_pid(Pid) ->
    _ = catch sys:terminate(Pid, shutdown, 5000),
    nil.

start_stdio_client_port(CmdBin, ArgsList, GleamSubject) ->
    Parent = self(),
    OpenRef = make_ref(),
    Cmd = binary_to_list(CmdBin),
    Args = [binary_to_list(A) || A <- ArgsList],
    case resolve_stdio_executable(Cmd) of
        {error, Reason} -> {error, Reason};
        {ok, Executable} ->
            {Pid, Monitor} = spawn_monitor(fun() ->
                try erlang:open_port(
                    {spawn_executable, Executable},
                    [stream, binary, use_stdio, exit_status, {args, Args}]
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
            catch erlang:port_close(Port),
            ok;
        close ->
            catch erlang:port_close(Port),
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
