-module(relay_stdio_input_ffi).
-export([write_from_any_process/2]).

%% Writes to a spawned child's standard input from a process that need not
%% own the port. The call blocks while the port is busy; a write to a port
%% that has closed is dropped.
write_from_any_process(Port, Bytes) ->
    try erlang:port_command(Port, Bytes) catch error:badarg -> ok end,
    nil.
