-module(relay_http_ffi).
-export([
    request/4,
    disconnect_after_first_sse_event/4,
    send_and_hold/4,
    read_until/3,
    abort_connection/1,
    with_unlistened_port/1
]).

%% A raw HTTP/1.1 client for the endpoint tests. It sends exactly the given
%% headers (plus Host, Content-Type and Content-Length, unless the caller
%% sets them), reads the response until the server closes the connection or
%% the body is complete, and decodes a chunked body. Server-sent event
%% streams use chunked encoding with `connection: close`.
request(Port, MethodBin, Headers, Body)
        when is_integer(Port), is_binary(MethodBin), is_binary(Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = request_bytes(Port, MethodBin, Headers, Body, <<"close">>),
            Result = case gen_tcp:send(Socket, Request) of
                ok -> read_response(Socket, <<>>);
                {error, Reason} -> {error, format(Reason)}
            end,
            _ = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, format(Reason)}
    end.

read_response(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Position, Length} ->
            HeaderLength = Position + Length,
            Head = binary:part(Acc, 0, Position),
            Rest = binary:part(Acc, HeaderLength, byte_size(Acc) - HeaderLength),
            [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
            Status = status_code(StatusLine),
            ResponseHeaders = [parse_header(Line) || Line <- HeaderLines, Line =/= <<>>],
            case response_body(Socket, ResponseHeaders, Rest) of
                {ok, ResponseBody} -> {ok, {Status, ResponseHeaders, ResponseBody}};
                {error, Reason} -> {error, format(Reason)}
            end;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 7000) of
                {ok, Chunk} -> read_response(Socket, <<Acc/binary, Chunk/binary>>);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

response_body(Socket, Headers, Rest) ->
    case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
        {_, Encoding} ->
            case string:lowercase(Encoding) of
                <<"chunked">> -> dechunk(Socket, Rest, <<>>);
                _ -> read_to_close(Socket, Rest)
            end;
        false ->
            case lists:keyfind(<<"content-length">>, 1, Headers) of
                {_, Raw} -> read_length(Socket, Rest, binary_to_integer(Raw));
                false -> read_to_close(Socket, Rest)
            end
    end.

read_length(_Socket, Acc, Length) when byte_size(Acc) >= Length ->
    {ok, binary:part(Acc, 0, Length)};
read_length(Socket, Acc, Length) ->
    case gen_tcp:recv(Socket, 0, 7000) of
        {ok, Chunk} -> read_length(Socket, <<Acc/binary, Chunk/binary>>, Length);
        {error, closed} -> {ok, Acc};
        {error, Reason} -> {error, Reason}
    end.

read_to_close(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 7000) of
        {ok, Chunk} -> read_to_close(Socket, <<Acc/binary, Chunk/binary>>);
        {error, closed} -> {ok, Acc};
        {error, Reason} -> {error, Reason}
    end.

dechunk(Socket, Acc, Body) ->
    case binary:match(Acc, <<"\r\n">>) of
        nomatch -> more(Socket, Acc, Body);
        {Position, 2} ->
            SizeLine = binary:part(Acc, 0, Position),
            [SizeHex | _] = binary:split(SizeLine, <<";">>),
            Size = binary_to_integer(string:trim(SizeHex), 16),
            Start = Position + 2,
            case Size of
                0 -> {ok, Body};
                _ when byte_size(Acc) >= Start + Size + 2 ->
                    Data = binary:part(Acc, Start, Size),
                    Next = Start + Size + 2,
                    dechunk(Socket, binary:part(Acc, Next, byte_size(Acc) - Next),
                            <<Body/binary, Data/binary>>);
                _ -> more(Socket, Acc, Body)
            end
    end.

more(Socket, Acc, Body) ->
    case gen_tcp:recv(Socket, 0, 7000) of
        {ok, Chunk} -> dechunk(Socket, <<Acc/binary, Chunk/binary>>, Body);
        {error, closed} -> {ok, Body};
        {error, Reason} -> {error, Reason}
    end.

parse_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] -> {string:lowercase(Name), string:trim(Value)};
        [Name] -> {string:lowercase(Name), <<>>}
    end.

status_code(StatusLine) ->
    case binary:split(StatusLine, <<" ">>, [global]) of
        [_, Code | _] -> binary_to_integer(Code);
        _ -> 0
    end.

%% Sends a request, reads the response head and the body up to its first
%% `data:` event, then resets the connection. Returns the status.
disconnect_after_first_sse_event(Port, Method, Headers, Body)
        when is_integer(Port), is_binary(Method), is_binary(Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = request_bytes(Port, Method, Headers, Body, <<"keep-alive">>),
            Result = case gen_tcp:send(Socket, Request) of
                ok -> read_response_header_and_event(Socket, <<>>);
                {error, Reason} -> {error, format(Reason)}
            end,
            _ = inet:setopts(Socket, [{linger, {true, 0}}]),
            _ = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, format(Reason)}
    end.

%% Sends one request and keeps its connection open without reading the
%% response, so a test can read it in steps or close it while it runs.
send_and_hold(Port, Method, Headers, Body)
        when is_integer(Port), is_binary(Method), is_binary(Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = request_bytes(Port, Method, Headers, Body, <<"keep-alive">>),
            case gen_tcp:send(Socket, Request) of
                ok -> {ok, Socket};
                {error, Reason} ->
                    _ = gen_tcp:close(Socket),
                    {error, format(Reason)}
            end;
        {error, Reason} ->
            {error, format(Reason)}
    end.

%% Reads a held connection until `Needle` appears in what it has received
%% since the last read, or `TimeoutMs` passes. Returns the bytes read, up to
%% and including the needle; later bytes stay buffered for the next read.
read_until(Socket, Needle, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    Buffered = case get({relay_http_buffer, Socket}) of
        undefined -> <<>>;
        Bytes -> Bytes
    end,
    read_until(Socket, Needle, Deadline, Buffered).

read_until(Socket, Needle, Deadline, Acc) ->
    case binary:match(Acc, Needle) of
        {Position, Length} ->
            End = Position + Length,
            put({relay_http_buffer, Socket}, binary:part(Acc, End, byte_size(Acc) - End)),
            {ok, binary:part(Acc, 0, End)};
        nomatch ->
            Remaining = Deadline - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true ->
                    put({relay_http_buffer, Socket}, Acc),
                    {error, <<"timeout">>};
                false ->
                    case gen_tcp:recv(Socket, 0, Remaining) of
                        {ok, Chunk} -> read_until(Socket, Needle, Deadline, <<Acc/binary, Chunk/binary>>);
                        {error, Reason} ->
                            put({relay_http_buffer, Socket}, Acc),
                            {error, format(Reason)}
                    end
            end
    end.

%% Resets the connection and reports the bytes the server had sent on it
%% that no read consumed.
abort_connection(Socket) ->
    Buffered = case erase({relay_http_buffer, Socket}) of
        undefined -> <<>>;
        Bytes -> Bytes
    end,
    Received = case gen_tcp:recv(Socket, 0, 0) of
        {ok, More} -> More;
        {error, _} -> <<>>
    end,
    _ = inet:setopts(Socket, [{linger, {true, 0}}]),
    _ = gen_tcp:close(Socket),
    <<Buffered/binary, Received/binary>>.

request_bytes(Port, Method, Headers, Body, Connection) ->
    Lowered = [string:lowercase(Name) || {Name, _} <- Headers, is_binary(Name)],
    Defaults = [
        {<<"host">>, <<"Host">>, [<<"127.0.0.1:">>, integer_to_binary(Port)]},
        {<<"connection">>, <<"Connection">>, Connection},
        {<<"content-type">>, <<"Content-Type">>, <<"application/json">>}
    ],
    DefaultHeaders = [
        [Name, <<": ">>, Value, <<"\r\n">>]
        || {Key, Name, Value} <- Defaults,
           not lists:member(Key, Lowered)
    ],
    ExtraHeaders = [
        [Name, <<": ">>, Value, <<"\r\n">>]
        || {Name, Value} <- Headers,
           is_binary(Name),
           is_binary(Value)
    ],
    [
        string:uppercase(Method),
        <<" /mcp HTTP/1.1\r\n">>,
        DefaultHeaders,
        <<"Content-Length: ">>,
        integer_to_binary(byte_size(Body)),
        <<"\r\n">>,
        ExtraHeaders,
        <<"\r\n">>,
        Body
    ].

read_response_header_and_event(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Position, Length} ->
            HeaderLength = Position + Length,
            Header = binary:part(Acc, 0, HeaderLength),
            Body = binary:part(Acc, HeaderLength, byte_size(Acc) - HeaderLength),
            [StatusLine | _] = binary:split(Header, <<"\r\n">>),
            read_first_sse_event(Socket, status_code(StatusLine), Body);
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_response_header_and_event(Socket, <<Acc/binary, Chunk/binary>>);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

read_first_sse_event(Socket, Status, Acc) ->
    case binary:match(Acc, <<"data:">>) of
        {_, _} -> {ok, Status};
        nomatch when byte_size(Acc) > 65536 -> {error, <<"response_chunk_too_large">>};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_first_sse_event(Socket, Status, <<Acc/binary, Chunk/binary>>);
                {error, Reason} -> {error, format(Reason)}
            end
    end.

format(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).

%% Reserve a loopback TCP port without listening. Connections are refused
%% while the callback runs, and another test cannot reuse the same port.
with_unlistened_port(Callback) ->
    {ok, Socket} = socket:open(inet, stream, tcp),
    try
        ok = socket:bind(Socket, #{family => inet, addr => {127, 0, 0, 1}, port => 0}),
        {ok, #{port := Port}} = socket:sockname(Socket),
        Callback(Port)
    after
        socket:close(Socket)
    end.
