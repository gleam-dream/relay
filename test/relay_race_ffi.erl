-module(relay_race_ffi).
-export([drain/0]).

%% Drops messages an earlier test left in the shared test process, so a
%% test's mailbox check sees only its own messages.
drain() ->
    receive _ -> drain()
    after 0 -> nil
    end.
