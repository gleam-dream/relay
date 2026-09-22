-module(relay_url_ffi).
-export([valid_ipv6/1, valid_bind_host/1, readable_file/1, path_without_controls/1]).

valid_ipv6(Address) when is_binary(Address) ->
    case inet:parse_address(binary_to_list(Address)) of
        {ok, Tuple} when tuple_size(Tuple) =:= 8 -> true;
        _ -> false
    end.

valid_bind_host(<<"localhost">>) -> true;
valid_bind_host(Host) when is_binary(Host) ->
    case inet:parse_address(binary_to_list(Host)) of
        {ok, _} -> true;
        _ -> false
    end.

readable_file(Path) when is_binary(Path) ->
    case filelib:is_regular(binary_to_list(Path)) of
        false -> false;
        true ->
            case file:open(Path, [read, binary]) of
                {ok, Device} -> file:close(Device) =:= ok;
                _ -> false
            end
    end.

path_without_controls(Path) when is_binary(Path) ->
    lists:all(fun(Byte) -> Byte > 32 andalso Byte =/= 127 end,
              binary_to_list(Path)).
