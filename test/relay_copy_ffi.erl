%% Copy-cost probes: how many bytes a term occupies once copied to another
%% process, and every term that crosses a process boundary while a function
%% runs (messages sent and closures handed to new processes).
-module(relay_copy_ffi).
-export([flat_bytes/1, crossings/1, heap_bytes/0, shared_bytes/0]).

flat_bytes(Term) ->
    erts_debug:flat_size(Term) * erlang:system_info(wordsize).

%% The calling process's live heap after a collection: what it holds that
%% was copied in, as opposed to shared literals.
heap_bytes() ->
    erlang:garbage_collect(),
    {total_heap_size, Words} = process_info(self(), total_heap_size),
    Words * erlang:system_info(wordsize).

%% Bytes the node keeps in persistent_term, Relay's shared storage.
shared_bytes() ->
    maps:get(memory, persistent_term:info()).

%% Runs Run() with send and spawn tracing on every process, then returns
%% #(Result, [#(Kind, Label, Bytes)]) for each message sent and each process
%% spawned while it ran. Labels name the message tag or the spawned closure.
crossings(Run) ->
    Parent = self(),
    Tracer = spawn(fun() -> collect(Parent, []) end),
    Session = trace:session_create(relay_copy_probe, Tracer, []),
    trace:process(Session, all, true, [send, procs]),
    Result = try Run() after
        trace:process(Session, all, false, [send, procs]),
        %% Trace messages arrive asynchronously: wait until every one
        %% generated while tracing reached the tracer, so none is lost
        %% after `done`.
        Delivered = trace:delivered(Session, all),
        receive {trace_delivered, all, Delivered} -> ok end,
        trace:session_destroy(Session)
    end,
    Ref = make_ref(),
    Tracer ! {done, Ref},
    receive {Ref, Seen} -> {Result, lists:reverse(Seen)} end.

collect(Parent, Seen) ->
    receive
        {done, Ref} -> Parent ! {Ref, Seen};
        {trace, _From, send, Message, _To} ->
            collect(Parent, [{<<"send">>, label(Message), flat_bytes(Message)} | Seen]);
        {trace, _From, spawn, _Child, {M, F, Args}} ->
            collect(Parent, [{<<"spawn">>, spawn_label(M, F, Args), flat_bytes(Args)} | Seen]);
        _ -> collect(Parent, Seen)
    end.

label({Ref, Message}) when is_reference(Ref) -> label(Message);
label(Message) when is_tuple(Message), tuple_size(Message) > 0 ->
    term_label(element(1, Message));
label(Message) -> term_label(Message).

term_label(Term) when is_atom(Term) -> atom_to_binary(Term);
term_label(Term) when is_reference(Term) -> <<"ref">>;
term_label(Term) when is_function(Term) -> fun_label(Term);
term_label(Term) when is_tuple(Term), tuple_size(Term) > 0 -> term_label(element(1, Term));
term_label(_) -> <<"other">>.

spawn_label(M, F, Args) ->
    Funs = [fun_label(A) || A <- Args, is_function(A)] ++
        [fun_label(A) || L <- Args, is_list(L), A <- L, is_function(A)],
    iolist_to_binary([atom_to_binary(M), $:, atom_to_binary(F),
                      [[$\s, L] || L <- Funs]]).

fun_label(Fun) ->
    {module, M} = erlang:fun_info(Fun, module),
    {name, N} = erlang:fun_info(Fun, name),
    iolist_to_binary([atom_to_binary(M), $:, atom_to_binary(N)]).
