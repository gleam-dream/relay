# Relay benchmarks

Relay keeps one small benchmark. It exists to compare two builds of Relay on
the same machine, not to state a latency a deployment can expect.

## HTTP `tools/call` decode cost

`dev/relay_decode_bench.gleam` mounts an endpoint with one tool and sends the
same `tools/call` request through `http.handle` in a loop, for a body of about
1 KiB, 100 KiB and 1 MiB. It prints the mean wall-clock time per request. The
request never crosses a socket, so the number covers header checks, body
decoding, the per-request processes, the handler and response encoding.

```sh
nix develop --command gleam run -m relay_decode_bench
```

To compare two builds, run the command at least three times on each, back to
back on the same machine, and compare medians. The loop is short and the
machine's other load moves the result by several percent between runs.

## Recorded comparison

Measured on 2026-11-24 on a shared 10-core Apple Silicon Mac with other builds
running, three runs each, median and range in milliseconds per request.
"Before" decodes the request body six times for one `tools/call` (routing,
admission and the reducer each parse the body and extract the arguments) and
parses the response twice. "After" takes routing and admission from one parse
in the endpoint and classifies the response once.

| Body   | Before              | After               |
| ------ | ------------------- | ------------------- |
| 1.3 kB | 0.156 (0.151-0.186) | 0.139 (0.139-0.140) |
| 110 kB | 3.33 (3.20-3.38)    | 2.44 (2.42-2.53)    |
| 1.1 MB | 32.4 (31.4-33.9)    | 25.9 (23.7-26.3)    |

## Limits

The benchmark measures one request at a time on one scheduler's worth of work.
It says nothing about concurrent load, sockets, TLS or streaming.
