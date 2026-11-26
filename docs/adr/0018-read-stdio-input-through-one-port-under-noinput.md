# Read stdio input through one port under -noinput

<a id="adr-0018"></a>

## Decision

A stdio server reads standard input through one stream port on descriptor 0
and nothing else. It serves only in a VM started with `-noinput`, and returns
`StdinOwnedByVm` before reading anything otherwise. Serving also moves every
logger handler that writes to standard output to standard error, and makes
standard error the group leader of the runtime and its handlers.

## Rationale

Three requirements hold together: a request shorter than any read size is
answered while the pipe stays open; an oversized frame is refused while it
grows, never after it is whole in memory; and standard input has one reader.
The documented ways to read the descriptor give these properties:

- A raw file read of a pipe returns only when its whole count has arrived or
  the pipe closes, so a short request waits for more input.
- The `user` I/O server owns the descriptor unless the VM runs with
  `-noinput`. For a pipe it can run only in cooked mode:
  `shell:start_interactive({noshell, raw})` refuses when standard input and
  output are not terminals. In cooked mode it collects a whole line before
  any `get_line` or `get_until` caller sees it, so no bound applies while the
  line grows.
- A stream port on the descriptor delivers each read as it completes, so the
  framer can refuse a frame while it grows. While the terminal reader holds
  the descriptor, opening the port takes the descriptor's readiness
  notifications from it, and the emulator logs an error report about it.
  That works, but it is not a documented behaviour to build on.

So the port is the only reader that meets the first two requirements, and
`-noinput` is the documented way to give it the descriptor alone. An earlier
design kept two readers, the I/O server by default and the port under
`-noinput`; it bounded frames only in the second mode.

## Consequences

- Every stdio server launch passes `-noinput`, for example
  `ERL_FLAGS=-noinput`. A launch without it fails at once with a typed error
  that names the flag.
- A port cannot be paused, so the pipe does not hold back a parent that
  writes faster than the server frames. [ADR 0019](0019-bound-unframed-stdio-input.md)
  supersedes the earlier choice to let that input wait unbounded: the server
  stops when the unframed input passes a limit.
- The logger change lasts for the rest of the VM's life. Processes started
  before `serve` keep their group leader and must not print to standard
  output; `erlang:display` writes to the descriptor directly and is outside
  Relay's reach.

## Verification

Tests in `test/relay/stdio_test.gleam` drive a stdio server in a spawned VM
over OS pipes:

- `default_settings_answer_a_small_request_while_stdin_stays_open_test`: a
  request shorter than one read is answered while the pipe stays open.
- `oversized_frame_is_refused_before_its_newline_arrives_test`: an oversized
  frame is refused while it grows.
- `stdio_refuses_to_serve_while_the_vm_reads_stdin_test`, in the test VM,
  which runs without `-noinput`: `serve` returns `StdinOwnedByVm` before it
  reads anything.
- `log_and_print_output_while_serving_stays_off_stdout_test`: logger output
  and handler `io` output reach standard error, never standard output.

ADR 0019 lists the tests for the bound on input not yet framed.
