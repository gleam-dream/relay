-module(relay_stdio_noise_ffi).
-export([make_noise/0]).

%% Writes to every place a library or handler commonly writes to while a
%% stdio server is serving: the logger, the process's group leader, and a
%% crash report from a process that dies.
make_noise() ->
    logger:error("relay test: a log line while serving"),
    io:format("relay test: printed by a handler~n"),
    {Pid, Ref} = spawn_monitor(fun() -> erlang:error(relay_test_crash) end),
    receive {'DOWN', Ref, process, Pid, _} -> ok end,
    nil.
