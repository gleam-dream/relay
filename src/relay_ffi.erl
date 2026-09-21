-module(relay_ffi).
-export([
    is_null/1,
    dynamic_to_json_string/1,
    unique_integer/0,
    rescue_run/1,
    monotonic_time_ms/0,
    set_stdio_binary/0,
    read_stdin/1,
    write_stdout/1,
    write_stderr/1,
    spawn_stdio_child/1,
    send_to_child/2,
    receive_from_child/2,
    close_child/1,
    sha256_hex/1,
    read_file/1,
    git_head/1
]).

is_null(null) -> true;
is_null(nil) -> true;
is_null(_) -> false.

dynamic_to_json_string(Data) ->
    try
        iolist_to_binary(json:encode(Data))
    catch
        _:_ -> <<"{}"/utf8>>
    end.

unique_integer() ->
    erlang:unique_integer([positive, monotonic]).

monotonic_time_ms() ->
    erlang:monotonic_time(millisecond).

rescue_run(Fun) ->
    try
        {ok, Fun()}
    catch
        _Class:Reason:_Stack ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

set_stdio_binary() ->
    io:setopts(standard_io, [{binary, true}, {encoding, utf8}]),
    io:setopts(standard_error, [{binary, true}, {encoding, utf8}]),
    ok.

read_stdin(_ChunkSize) ->
    case io:get_line(standard_io, "") of
        eof -> read_eof;
        {error, Reason} ->
            {read_failed, unicode:characters_to_binary(io_lib:format("~p", [Reason]))};
        Data when is_binary(Data) ->
            {read_chunk, Data};
        Data when is_list(Data) ->
            {read_chunk, unicode:characters_to_binary(Data)}
    end.

write_stdout(Bin) ->
    case io:put_chars(standard_io, Bin) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

write_stderr(Bin) ->
    case io:put_chars(standard_error, Bin) of
        ok -> {ok, nil};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

spawn_stdio_child(Cmd) ->
    Port = erlang:open_port({spawn, binary_to_list(Cmd)}, [stream, binary, use_stdio]),
    Port.

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

