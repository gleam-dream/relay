-module(relay_http_ffi).
-export([request/4, disconnect_after_first_sse_event/4, send_and_hold/4, abort_connection/1]).

request(Port, MethodBin, Headers, Body) when is_integer(Port), is_binary(MethodBin), is_binary(Body) ->
    _ = application:ensure_all_started(inets),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/mcp",
    Method = method(binary_to_list(MethodBin)),
    HeaderList = [
        {binary_to_list(Name), binary_to_list(Value)}
        || {Name, Value} <- Headers,
           is_binary(Name),
           is_binary(Value)
    ],
    case httpc:request(
        Method,
        {Url, HeaderList, "application/json", Body},
        [{timeout, 7000}],
        [{body_format, binary}]
    ) of
        {ok, {{_Version, Status, _Reason}, ResponseHeaders, ResponseBody}} ->
            {ok, {Status, [
                {list_to_binary(Name), list_to_binary(Value)}
                || {Name, Value} <- ResponseHeaders
            ], ResponseBody}};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

method("get") -> get;
method("post") -> post;
method("put") -> put;
method("delete") -> delete;
method(_) -> post.

disconnect_after_first_sse_event(Port, Method, Headers, Body)
        when is_integer(Port), is_binary(Method), is_binary(Body) ->
    disconnect_after(Port, Method, Headers, Body).

disconnect_after(Port, Method, Headers, Body)
        when is_integer(Port), is_binary(Method), is_binary(Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            ExtraHeaders = [
                [Name, <<": ">>, Value, <<"\r\n">>]
                || {Name, Value} <- Headers,
                   is_binary(Name),
                   is_binary(Value)
            ],
            Request = [
                Method,
                <<" /mcp HTTP/1.1\r\nHost: 127.0.0.1:">>,
                integer_to_binary(Port),
                <<"\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: ">>,
                integer_to_binary(byte_size(Body)),
                <<"\r\n">>,
                ExtraHeaders,
                <<"\r\n">>,
                Body
            ],
            Result = case gen_tcp:send(Socket, Request) of
                ok -> read_response_header_and_event(Socket, <<>>);
                {error, Reason} -> {error, Reason}
            end,
            _ = inet:setopts(Socket, [{linger, {true, 0}}]),
            _ = gen_tcp:close(Socket),
            Result;
        {error, Reason} ->
            {error, Reason}
    end.

%% Sends one request and keeps its connection open without reading the
%% response, so a test can close the connection while the call runs.
send_and_hold(Port, Method, Headers, Body)
        when is_integer(Port), is_binary(Method), is_binary(Body) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = request_bytes(Port, Method, Headers, Body),
            case gen_tcp:send(Socket, Request) of
                ok -> {ok, Socket};
                {error, Reason} ->
                    _ = gen_tcp:close(Socket),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Closes the connection and reports the bytes the server had sent on it.
abort_connection(Socket) ->
    Received = case gen_tcp:recv(Socket, 0, 0) of
        {ok, Bytes} -> Bytes;
        {error, _} -> <<>>
    end,
    _ = inet:setopts(Socket, [{linger, {true, 0}}]),
    _ = gen_tcp:close(Socket),
    Received.

request_bytes(Port, Method, Headers, Body) ->
    ExtraHeaders = [
        [Name, <<": ">>, Value, <<"\r\n">>]
        || {Name, Value} <- Headers,
           is_binary(Name),
           is_binary(Value)
    ],
    [
        Method,
        <<" /mcp HTTP/1.1\r\nHost: 127.0.0.1:">>,
        integer_to_binary(Port),
        <<"\r\nConnection: keep-alive\r\nContent-Type: application/json\r\nContent-Length: ">>,
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
            case response_status(Header) of
                {ok, Status} -> read_first_sse_event(Socket, Status, Body);
                Error -> Error
            end;
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_response_header_and_event(Socket, <<Acc/binary, Chunk/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

read_first_sse_event(Socket, Status, Acc) ->
    case binary:match(Acc, <<"data:">>) of
        {_, _} -> {ok, Status};
        nomatch when byte_size(Acc) > 65536 -> {error, response_chunk_too_large};
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_first_sse_event(Socket, Status, <<Acc/binary, Chunk/binary>>);
                {error, Reason} -> {error, Reason}
            end
    end.

response_status(Headers) ->
    [StatusLine | _] = binary:split(Headers, <<"\r\n">>, [global]),
    case binary:split(StatusLine, <<" ">>, [global]) of
        [_, Code | _] -> {ok, binary_to_integer(Code)};
        _ -> {error, invalid_status_line}
    end.
