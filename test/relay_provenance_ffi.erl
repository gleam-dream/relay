-module(relay_provenance_ffi).
-export([ci_environment/0]).

%% True when the CI variable is set, as GitHub Actions does.
ci_environment() ->
    case os:getenv("CI") of
        false -> false;
        "" -> false;
        _ -> true
    end.
