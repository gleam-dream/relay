# Bound unframed stdio input

<a id="adr-0019"></a>

## Decision

A stdio server holds at most `stdio.Config.max_unframed_bytes` of standard
input that it has read but not yet framed and submitted, 4 MiB by default.
The reader counts the bytes it has sent to the serving process and subtracts
the bytes the serving process reports framed. When the count passes the
limit, the reader stops reading, its port closes, and `serve` returns
`UnframedInputTooLarge`. The limit must be at least the runtime's frame limit
and 64 KiB, one pipe read, or `serve` returns `InvalidUnframedLimit` before
any I/O.

This supersedes the consequence in [ADR 0018](0018-read-stdio-input-through-one-port-under-noinput.md)
that input not yet framed waits unbounded in the reader's mailbox. The rest
of ADR 0018 stands.

## Rationale

A port cannot be paused, so the pipe gives no back-pressure once the port
reads it. A write to standard output that stalls holds the serving process
for up to the write timeout, and a parent that keeps writing during that time
grew the serving process's mailbox without limit. Trusting the parent does
not bound memory against a parent that is merely fast or broken.

Stopping is the only bounded outcome the port allows: the alternative, a
reader that drops input, would answer some requests and silently lose
others. Four frames of headroom lets ordinary bursts through, and a frame
that fits the frame limit always fits the input limit.

## Consequences

- Input past the limit is not read. A parent sees the server exit with the
  error on standard error, as for a broken standard output.
- The count is an upper bound: a chunk the serving process framed but has
  not yet reported still counts, so the server can stop slightly before the
  backlog reaches the limit.

## Verification

- `unframed_input_past_its_limit_stops_the_server_test` stalls standard
  output on a large answer, writes 1 MiB of requests to a server with a
  64 KiB limit, and sees `serve` stop with `UnframedInputTooLarge`.
- `unframed_limit_below_a_frame_or_a_pipe_read_is_refused_test` checks the
  default and both lower bounds.
