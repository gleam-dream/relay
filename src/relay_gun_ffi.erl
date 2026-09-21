-module(relay_gun_ffi).
-export([
    open/4,
    request/8,
    close/1,
    unique_integer/0
]).

open(HostBin, Port, Secure, Timeout) ->
    Host = binary_to_list(HostBin),
    Transport = case Secure of true -> tls; false -> tcp end,
    BaseOpts = #{transport => Transport, protocols => [http], retry => 0},
    Opts = case Secure of
        true -> BaseOpts#{tls_opts => [{verify, verify_peer}, {cacerts, public_key:cacerts_get()}]};
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
        StreamRef -> await_response(Pid, StreamRef, Deadline, Limit, undefined, <<>>)
    catch
        Class:Reason -> {error, printable({Class, Reason})}
    end.

await_response(Pid, StreamRef, Deadline, Limit, undefined, Acc) ->
    receive
        {gun_response, Pid, StreamRef, IsFin, Status, _Headers} ->
            case IsFin of
                fin -> {ok, {Status, Acc}};
                nofin -> await_response(Pid, StreamRef, Deadline, Limit, Status, Acc)
            end;
        {gun_error, Pid, StreamRef, Reason} -> {error, printable(Reason)};
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} -> connection_failure(Reason)
    after remaining_timeout(Deadline) ->
        catch gun:cancel(Pid, StreamRef),
        {error, <<"request timed out">>}
    end;
await_response(Pid, StreamRef, Deadline, Limit, Status, Acc) ->
    receive
        {gun_data, Pid, StreamRef, IsFin, Data} ->
            NewSize = byte_size(Acc) + byte_size(Data),
            case NewSize > Limit of
                true ->
                    catch gun:cancel(Pid, StreamRef),
                    {error, <<"response exceeded configured byte limit">>};
                false ->
                    NewAcc = <<Acc/binary, Data/binary>>,
                    case IsFin of
                        fin -> {ok, {Status, NewAcc}};
                        nofin ->
                            ok = gun:update_flow(Pid, StreamRef, 1),
                            await_response(Pid, StreamRef, Deadline, Limit, Status, NewAcc)
                    end
            end;
        {gun_error, Pid, StreamRef, Reason} -> {error, printable(Reason)};
        {gun_down, Pid, _Protocol, Reason, _KilledStreams} -> connection_failure(Reason)
    after remaining_timeout(Deadline) ->
        catch gun:cancel(Pid, StreamRef),
        {error, <<"request timed out">>}
    end.

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

connection_failure(shutdown) -> {error, <<"cancelled">>};
connection_failure(normal) -> {error, <<"cancelled">>};
connection_failure(Reason) -> {error, printable(Reason)}.
