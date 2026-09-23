-module(relay_gun_ffi).
-export([
    open/4,
    open_with_ca/5,
    request/8,
    request_typed/8,
    open_sse/6,
    next_sse/2,
    close_sse/1,
    close/1,
    unique_integer/0
]).

open(HostBin, Port, Secure, Timeout) ->
    open_with_ca(HostBin, Port, Secure, undefined, Timeout).

open_with_ca(HostBin, Port, Secure, CaCertFileBin, Timeout) ->
    Host = binary_to_list(HostBin),
    Transport = case Secure of true -> tls; false -> tcp end,
    BaseOpts = #{transport => Transport, protocols => [http], retry => 0},
    Opts = case Secure of
        true ->
            TlsOpts = case CaCertFileBin of
                undefined ->
                    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}];
                <<>> ->
                    [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}];
                CaFile when is_binary(CaFile) ->
                    [{verify, verify_peer}, {cacertfile, binary_to_list(CaFile)}]
            end,
            BaseOpts#{tls_opts => TlsOpts};
        false -> BaseOpts
    end,
    case gun:open(Host, Port, Opts) of
        {ok, Pid} ->
            case gun:await_up(Pid, Timeout) of
                {ok, _Protocol} -> {ok, Pid};
                {error, Reason} ->
                    catch gun:close(Pid),
                    {error, printable(Reason)}
            end;
        {error, Reason} -> {error, printable(Reason)}
    end.

request(Pid, PathBin, Body, MethodBin, NameBin, VersionBin, Timeout, Limit) ->
    case request_typed(Pid, PathBin, Body, MethodBin, NameBin, VersionBin, Timeout, Limit) of
        {error, Failure} -> {error, failure_text(Failure)};
        Success -> Success
    end.

request_typed(Pid, PathBin, Body, MethodBin, NameBin, VersionBin, Timeout, Limit) ->
    Monitor = erlang:monitor(process, Pid),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    BaseHeaders = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"application/json">>},
        {<<"mcp-protocol-version">>, VersionBin},
        {<<"mcp-method">>, MethodBin}
    ],
    Headers = case NameBin of
        <<>> -> BaseHeaders;
        _ -> BaseHeaders ++ [{<<"mcp-name">>, NameBin}]
    end,
    Flow = 1,
    try gun:request(Pid, <<"POST">>, PathBin, Headers, Body,
                    #{reply_to => self(), flow => Flow}) of
        StreamRef -> await_response(Pid, StreamRef, Monitor, Deadline, Limit, undefined, <<>>)
    catch
        Class:CatchReason -> {error, {transport_fault, printable({Class, CatchReason})}}
    after
        erlang:demonitor(Monitor, [flush])
    end.

await_response(Pid, StreamRef, Monitor, Deadline, Limit, undefined, Acc) ->
    receive
        {gun_response, Pid, StreamRef, IsFin, Status, _Headers} ->
            case IsFin of
                fin -> {ok, {Status, Acc}};
                nofin -> await_response(Pid, StreamRef, Monitor, Deadline, Limit, Status, Acc)
            end;
        {gun_error, Pid, StreamRef, Reason} -> {error, gun_failure(Reason)};
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} -> connection_failure(Reason);
        {'DOWN', Monitor, process, Pid, Reason} -> connection_failure(Reason)
    after remaining_timeout(Deadline) ->
        catch gun:cancel(Pid, StreamRef),
        {error, request_timed_out}
    end;
await_response(Pid, StreamRef, Monitor, Deadline, Limit, Status, Acc) ->
    receive
        {gun_data, Pid, StreamRef, IsFin, Data} ->
            NewSize = byte_size(Acc) + byte_size(Data),
            case NewSize > Limit of
                true ->
                    catch gun:cancel(Pid, StreamRef),
                    {error, response_limit_exceeded};
                false ->
                    NewAcc = <<Acc/binary, Data/binary>>,
                    case IsFin of
                        fin -> {ok, {Status, NewAcc}};
                        nofin ->
                            ok = gun:update_flow(Pid, StreamRef, 1),
                            await_response(Pid, StreamRef, Monitor, Deadline, Limit, Status, NewAcc)
                    end
            end;
        {gun_error, Pid, StreamRef, Reason} -> {error, gun_failure(Reason)};
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} -> connection_failure(Reason);
        {'DOWN', Monitor, process, Pid, Reason} -> connection_failure(Reason)
    after remaining_timeout(Deadline) ->
        catch gun:cancel(Pid, StreamRef),
        {error, request_timed_out}
    end.

open_sse(Pid, PathBin, Body, VersionBin, Timeout, Limit) ->
    Parent = self(),
    OpenRef = make_ref(),
    {ReaderPid, Monitor} = spawn_monitor(fun() ->
        open_sse_reader(Pid, PathBin, Body, VersionBin, Timeout, Limit,
                        Parent, OpenRef)
    end),
    receive
        {relay_sse_open, OpenRef, {ok, ReaderPid}} ->
            erlang:demonitor(Monitor, [flush]),
            {ok, ReaderPid};
        {relay_sse_open, OpenRef, {error, Reason}} ->
            erlang:demonitor(Monitor, [flush]),
            {error, printable(Reason)};
        {'DOWN', Monitor, process, ReaderPid, Reason} ->
            {error, printable(Reason)}
    after Timeout + 250 ->
        exit(ReaderPid, kill),
        {error, <<"request timed out">>}
    end.

open_sse_reader(Pid, PathBin, Body, VersionBin, Timeout, Limit, Parent, OpenRef) ->
    Headers = [
        {<<"content-type">>, <<"application/json">>},
        {<<"accept">>, <<"text/event-stream">>},
        {<<"mcp-protocol-version">>, VersionBin},
        {<<"mcp-method">>, <<"subscriptions/listen">>}
    ],
    ParentMon = erlang:monitor(process, Parent),
    try
        StreamRef = gun:request(Pid, <<"POST">>, PathBin, Headers, Body,
                                #{reply_to => self(), flow => 1}),
        await_sse_response(Pid, StreamRef, Timeout, Limit, Parent, OpenRef, ParentMon)
    catch
        Class:OpenSseReason ->
            Parent ! {relay_sse_open, OpenRef, {error, printable({Class, OpenSseReason})}},
            ok
    end.

await_sse_response(Pid, StreamRef, Timeout, Limit, Parent, OpenRef, ParentMon) ->
    receive
        {gun_response, Pid, StreamRef, nofin, 200, _Headers} ->
            Parent ! {relay_sse_open, OpenRef, {ok, self()}},
            sse_reader_loop(Pid, StreamRef, Limit, <<>>, [], 0,
                            none, ParentMon);
        {gun_response, Pid, StreamRef, fin, Status, _Headers} ->
            catch gun:cancel(Pid, StreamRef),
            Parent ! {relay_sse_open, OpenRef,
                      {error, unicode:characters_to_binary(
                          io_lib:format("unexpected fin response HTTP ~p", [Status]))}},
            ok;
        {gun_response, Pid, StreamRef, nofin, Status, _Headers} ->
            catch gun:cancel(Pid, StreamRef),
            Parent ! {relay_sse_open, OpenRef,
                      {error, unicode:characters_to_binary(io_lib:format("HTTP ~p", [Status]))}},
            ok;
        {gun_error, Pid, StreamRef, Reason} ->
            Parent ! {relay_sse_open, OpenRef, {error, printable(Reason)}},
            ok;
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} ->
            Parent ! {relay_sse_open, OpenRef, {error, printable(Reason)}},
            ok;
        {'DOWN', ParentMon, process, _Parent, _Reason} ->
            catch gun:cancel(Pid, StreamRef),
            ok
    after Timeout ->
        catch gun:cancel(Pid, StreamRef),
        Parent ! {relay_sse_open, OpenRef, {error, <<"request timed out">>}},
        ok
    end.

next_sse(ReaderPid, Timeout) ->
    Ref = make_ref(),
    ReaderPid ! {sse_next, self(), Ref, Timeout},
    receive
        {relay_sse_next, ReaderPid, Ref, {ok, Data}} -> {ok, Data};
        {relay_sse_next, ReaderPid, Ref, {error, Reason}} -> {error, printable(Reason)}
    after Timeout + 150 ->
        ReaderPid ! {sse_cancel_wait, Ref},
        {error, <<"timeout">>}
    end.

close_sse(ReaderPid) ->
    ReaderPid ! sse_close,
    ok.

sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue, QueueBytes, Waiter, ParentMon) ->
    receive
        {sse_next, Caller, Ref, Timeout} ->
            case Waiter of
                none ->
                    case Queue of
                        [Event | Rest] ->
                            Caller ! {relay_sse_next, self(), Ref, {ok, Event}},
                            NewBytes = QueueBytes - byte_size(Event),
                            case Rest of
                                [] -> catch gun:update_flow(Pid, StreamRef, 1);
                                _ -> ok
                            end,
                            sse_reader_loop(Pid, StreamRef, Limit, Buffer, Rest,
                                            NewBytes, none, ParentMon);
                        [] ->
                            Timer = erlang:send_after(Timeout, self(), {sse_next_timeout, Ref}),
                            sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                            QueueBytes, {Caller, Ref, Timer}, ParentMon)
                    end;
                _ ->
                    Caller ! {relay_sse_next, self(), Ref,
                              {error, <<"a subscription read is already pending">>}},
                    sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                    QueueBytes, Waiter, ParentMon)
            end;
        {sse_next_timeout, Ref} ->
            case Waiter of
                {Caller, Ref, _Timer} ->
                    Caller ! {relay_sse_next, self(), Ref, {error, <<"timeout">>}},
                    sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                    QueueBytes, none, ParentMon);
                _ ->
                    sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                    QueueBytes, Waiter, ParentMon)
            end;
        {sse_cancel_wait, Ref} ->
            case Waiter of
                {_Caller, Ref, Timer} ->
                    erlang:cancel_timer(Timer),
                    sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                    QueueBytes, none, ParentMon);
                _ ->
                    sse_reader_loop(Pid, StreamRef, Limit, Buffer, Queue,
                                    QueueBytes, Waiter, ParentMon)
            end;
        {gun_data, Pid, StreamRef, IsFin, Data} ->
            NewBuffer = <<Buffer/binary, Data/binary>>,
            {Remaining, Events} = extract_sse_events(NewBuffer, []),
            NewQueue = Queue ++ Events,
            NewQueueBytes = QueueBytes + event_bytes(Events),
            case byte_size(Remaining) + NewQueueBytes > Limit of
                true ->
                    catch gun:cancel(Pid, StreamRef),
                    sse_reader_fail(Buffer, Queue, QueueBytes,
                                    Waiter, ParentMon,
                                    <<"response exceeded configured byte limit">>);
                false ->
                    case IsFin of
                        fin ->
                            sse_reader_terminal(Pid, StreamRef, Limit, Remaining,
                                                NewQueue, NewQueueBytes, Waiter,
                                                ParentMon, <<"subscription closed">>);
                        nofin ->
                            case {NewQueue, Waiter} of
                                {[Event | Rest], {Caller, Ref, Timer}} ->
                                    erlang:cancel_timer(Timer),
                                    Caller ! {relay_sse_next, self(), Ref, {ok, Event}},
                                    NewQueueBytesAfterRead = NewQueueBytes - byte_size(Event),
                                    case Rest of
                                        [] -> catch gun:update_flow(Pid, StreamRef, 1);
                                        _ -> ok
                                    end,
                                    sse_reader_loop(Pid, StreamRef, Limit, Remaining,
                                                    Rest, NewQueueBytesAfterRead,
                                                    none, ParentMon);
                                {[], _} ->
                                    catch gun:update_flow(Pid, StreamRef, 1),
                                    sse_reader_loop(Pid, StreamRef, Limit, Remaining,
                                                    [], 0, Waiter, ParentMon);
                                {_, none} ->
                                    sse_reader_loop(Pid, StreamRef, Limit, Remaining,
                                                    NewQueue, NewQueueBytes, none, ParentMon)
                            end
                    end
            end;
        {gun_error, Pid, StreamRef, Reason} ->
            sse_reader_terminal(Pid, StreamRef, Limit, Buffer, Queue,
                                QueueBytes, Waiter, ParentMon, printable(Reason));
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} ->
            sse_reader_terminal(Pid, StreamRef, Limit, Buffer, Queue,
                                QueueBytes, Waiter, ParentMon, printable(Reason));
        {'DOWN', ParentMon, process, _, _} ->
            catch gun:cancel(Pid, StreamRef),
            ok;
        sse_close ->
            catch gun:cancel(Pid, StreamRef),
            case Waiter of
                {Caller, Ref, Timer} ->
                    erlang:cancel_timer(Timer),
                    Caller ! {relay_sse_next, self(), Ref,
                              {error, <<"subscription closed">>}};
                none -> ok
            end,
            ok
    end.

sse_reader_terminal(Pid, StreamRef, Limit, Buffer, Queue, QueueBytes,
                    Waiter, ParentMon, Reason) ->
    case {Queue, Waiter} of
        {[Event | Rest], {Caller, Ref, Timer}} ->
            erlang:cancel_timer(Timer),
            Caller ! {relay_sse_next, self(), Ref, {ok, Event}},
            sse_reader_terminal(Pid, StreamRef, Limit, Buffer, Rest,
                                QueueBytes - byte_size(Event), none,
                                ParentMon, Reason);
        {[], {Caller, Ref, Timer}} ->
            erlang:cancel_timer(Timer),
            Caller ! {relay_sse_next, self(), Ref, {error, Reason}},
            sse_reader_terminal(Pid, StreamRef, Limit, Buffer, [], 0,
                                none, ParentMon, Reason);
        {[], none} ->
            receive
                {sse_next, Caller, Ref, _Timeout} ->
                    Caller ! {relay_sse_next, self(), Ref, {error, Reason}},
                    sse_reader_terminal(Pid, StreamRef, Limit, Buffer, [], 0,
                                        none, ParentMon, Reason);
                sse_close -> ok;
                {'DOWN', ParentMon, process, _, _} -> ok
            end;
        {_, none} ->
            receive
                {sse_next, Caller, Ref, _Timeout} ->
                    [Event | Rest] = Queue,
                    Caller ! {relay_sse_next, self(), Ref, {ok, Event}},
                    sse_reader_terminal(Pid, StreamRef, Limit, Buffer, Rest,
                                        QueueBytes - byte_size(Event), none,
                                        ParentMon, Reason);
                sse_close -> ok;
                {'DOWN', ParentMon, process, _, _} -> ok
            end
    end.

sse_reader_fail(Buffer, Queue, QueueBytes, Waiter, ParentMon, Reason) ->
    sse_reader_terminal(undefined, undefined, 0, Buffer, Queue, QueueBytes,
                        Waiter, ParentMon, Reason).

event_bytes(Events) ->
    lists:sum([byte_size(Event) || Event <- Events]).

extract_sse_events(Buffer, Acc) ->
    case split_sse_event(Buffer) of
        {ok, Block, Rest} ->
            case parse_sse_block(Block) of
                ignore -> extract_sse_events(Rest, Acc);
                Data -> extract_sse_events(Rest, [Data | Acc])
            end;
        no_event ->
            {Buffer, lists:reverse(Acc)}
    end.

split_sse_event(Buffer) ->
    case binary:match(Buffer, <<"\n\n">>) of
        {Position, Length} ->
            {ok,
             binary:part(Buffer, 0, Position),
             binary:part(Buffer, Position + Length, byte_size(Buffer) - Position - Length)};
        nomatch ->
            case binary:match(Buffer, <<"\r\n\r\n">>) of
                {Position, Length} ->
                    {ok,
                     binary:part(Buffer, 0, Position),
                     binary:part(Buffer, Position + Length, byte_size(Buffer) - Position - Length)};
                nomatch -> no_event
            end
    end.

parse_sse_block(Block) ->
    Lines = binary:split(Block, <<"\n">>, [global]),
    DataLines = lists:filtermap(fun(Line) ->
        case Line of
            <<"data:", RawData/binary>> -> {true, sse_data_line(RawData)};
            _ -> false
        end
    end, Lines),
    case DataLines of
        [] -> ignore;
        _ -> lists:foldl(fun(D, <<>>) -> D; (D, A) -> <<A/binary, "\n", D/binary>> end, <<>>, DataLines)
    end.

sse_data_line(<<" ", Data/binary>>) ->
    binary:replace(Data, <<"\r">>, <<>>, [global]);
sse_data_line(Data) ->
    binary:replace(Data, <<"\r">>, <<>>, [global]).

remaining_timeout(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).

close(Pid) when is_pid(Pid) ->
    catch gun:flush(Pid),
    catch gun:close(Pid),
    catch gun:flush(Pid),
    nil;
close(_) -> nil.

unique_integer() -> erlang:unique_integer([positive, monotonic]).

printable(Reason) when is_binary(Reason) -> Reason;
printable(Reason) -> unicode:characters_to_binary(io_lib:format("~0p", [Reason])).

connection_failure(_Reason) -> {error, connection_closed}.

gun_failure(cancelled) -> request_cancelled;
gun_failure({cancelled, _}) -> request_cancelled;
gun_failure(Reason) -> {transport_fault, printable(Reason)}.

failure_text(connection_closed) -> <<"connection closed">>;
failure_text(request_cancelled) -> <<"request cancelled">>;
failure_text(request_timed_out) -> <<"request timed out">>;
failure_text(response_limit_exceeded) -> <<"response exceeded configured byte limit">>;
failure_text({transport_fault, Message}) -> Message.
