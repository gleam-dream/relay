-module(relay_stdio_env_ffi).
-export([getenv/1, putenv/2]).

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
