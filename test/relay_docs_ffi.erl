-module(relay_docs_ffi).
-export([public_sources/0]).

%% Every public module's source path with its text. Modules under
%% src/relay/internal are excluded, matching gleam.toml's internal_modules.
public_sources() ->
    Paths = filelib:wildcard("src/relay/*.gleam"),
    [{unicode:characters_to_binary(Path), read(Path)} || Path <- lists:sort(Paths)].

read(Path) ->
    {ok, Text} = file:read_file(Path),
    Text.
