-module(relay_http_lifecycle_ffi).
-export([intentional_stop/1, unexpected_listener_exit/1]).
-include_lib("eunit/include/eunit.hrl").

%% Keep tracing and monitor messages in an isolated test coordinator.
intentional_stop(Start) -> isolated(fun() -> with_listener(Start, fun stop_in_order/3) end).
unexpected_listener_exit(Start) ->
    isolated(fun() -> with_listener(Start, fun(Owner, _Hub, Listener) ->
        Ref = monitor(process, Owner),
        exit(Listener, kill),
        ?assertEqual(killed, await_down(Ref, Owner))
    end) end).

isolated(Run) ->
    {Pid, Ref} = spawn_monitor(Run),
    ?assertEqual(normal, await_down(Ref, Pid)),
    nil.

with_listener(Start, Check) ->
    Test = self(),
    {Owner, Ref} = spawn_monitor(fun() ->
        Stop = Start(),
        {links, [Hub]} = process_info(self(), links),
        {links, Links} = process_info(Hub, links),
        [Listener] = Links -- [self()],
        Test ! {ready, self(), Hub, Listener},
        receive stop -> Stop() end,
        Test ! {stopped, self()},
        receive finish -> ok end
    end),
    receive
        {ready, Owner, Hub, Listener} ->
            try Check(Owner, Hub, Listener)
            after
                catch erlang:resume_process(Listener),
                catch erlang:resume_process(Hub),
                exit(Owner, kill),
                demonitor(Ref, [flush])
            end;
        {'DOWN', Ref, process, Owner, Reason} -> error({start_failed, Reason})
    after 2000 -> exit(Owner, kill), error(start_timeout)
    end.

stop_in_order(Owner, Hub, Listener) ->
    OwnerRef = monitor(process, Owner),
    HubRef = monitor(process, Hub),
    ListenerRef = monitor(process, Listener),
    erlang:trace(Hub, true, [send]),
    erlang:suspend_process(Listener),
    Owner ! stop,
    %% Wait for the real stop request before allowing the listener to finish.
    receive
        {trace, Hub, send, {system, _, {terminate, shutdown}}, Listener} -> ok
    after 2000 -> error(no_listener_stop_request)
    end,
    erlang:suspend_process(Hub),
    erlang:resume_process(Listener),
    ?assertEqual(shutdown, await_down(ListenerRef, Listener)),
    catch erlang:resume_process(Hub),
    %% The listener's intended shutdown must not become the hub's exit reason.
    ?assertEqual(normal, await_down(HubRef, Hub)),
    receive {stopped, Owner} -> ok
    after 2000 -> error(stop_did_not_return)
    end,
    ?assert(is_process_alive(Owner)),
    Owner ! finish,
    ?assertEqual(normal, await_down(OwnerRef, Owner)).

await_down(Ref, Pid) ->
    receive {'DOWN', Ref, process, Pid, Reason} -> Reason
    after 3000 -> error({down_timeout, Pid})
    end.
