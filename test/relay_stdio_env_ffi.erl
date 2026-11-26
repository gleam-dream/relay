-module(relay_stdio_env_ffi).
-export([getenv/1, putenv/2, windows_unset/2]).

%% The value of an environment variable of this OS process, or "" when the
%% variable is not set.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<"(unset)">>;
        Value -> unicode:characters_to_binary(Value)
    end.

putenv(Name, Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

%% The variables a stdio child launched on Windows would have unset, given
%% this inherited environment and the caller's additions.
windows_unset(Inherited, Added) ->
    Env = relay_ffi:child_environment(
        {win32, nt},
        [{binary_to_list(N), binary_to_list(V)} || {N, V} <- Inherited],
        Added
    ),
    [list_to_binary(Name) || {Name, false} <- Env].
