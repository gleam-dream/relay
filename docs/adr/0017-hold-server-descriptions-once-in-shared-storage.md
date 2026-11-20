# Hold server descriptions once in shared storage

<a id="adr-0017"></a>

## Decision

An HTTP endpoint holds its configuration with its current server description
once in `persistent_term`, one snapshot per registry generation. An admitted
request leases a handle to that snapshot; the request owner, the request
runtime and every invocation worker read the server through the handle. A
stdio server's runtime holds its own server the same way and holds it again
after registry changes. A keeper process frees a snapshot when its holder
releases it or exits; an endpoint releases an older generation once no
admitted request leases it.

Other connection runtimes (`runtime.start`, `runtime.supervised`,
`client.in_process`, `testing.connect`) keep the server on their own heap.
Their invocation workers capture only the invocation, which copies the one
tool it runs, never the runtime state or the rest of the catalog.

Closures and messages that cross process boundaries capture the handle and
plain values, never the configuration, the server or the runtime state. A
test bounds every crossing term of one HTTP request and one tool call, the
invocation worker's live heap, and snapshot release.

## Rationale

Combinator codecs are closure trees, and BEAM copies a closure's whole
environment, without sharing, whenever it is sent or spawned. Relay 0.2.1
passed the server in the request lease (twice: the lease and its
configuration), in each closure that started the request worker and
runtime, and in the runtime state captured by every invocation worker.
With 13 tools whose nested codecs follow the JSON Blueprint codec practice
(235 kB in all), one HTTP `tools/call` copied about 4 MB across seven
crossings, and every call on a connection runtime (stdio or in-process)
copied 249 kB into its worker. The copy grew
with the catalog, not with the request, which is the pattern that exhausted
memory in a production service built on JSON Blueprint 2.1.0.

A term read from `persistent_term` is a shared literal: neither spawn nor
send copies it. This was measured on Erlang/OTP 29, the version the
repository's development shell pins; the copy-cost probe's tracing needs
OTP 27 or later. Holding the catalog there makes per-request and
per-call copying independent of the number and codec size of registered
tools. After the change, the largest crossing of the same request is one
invocation worker's closure (about 22 kB, the one tool it runs, shared and not
copied) and the worker's live heap stays below 8 kB.

Alternatives considered:

- Capturing fewer values alone still copies the server into each request
  runtime and the tool into each worker: one copy per request that still
  grows with the catalog.
- Asking the endpoint actor for one tool per call serializes calls through
  that actor and still copies the tool.
- ETS copies on every lookup.

Which connection runtimes hold was decided by the repository owner on 20
November 2026 from these measurements (500 cycles, 20,000 idle processes, a
1 MB catalog that includes one 790 kB tool):

| Connection runtimes | 500 connect and close | 500 calls to the 790 kB tool |
| ------------------- | --------------------- | ---------------------------- |
| every one holds     | 612–1,467 ms          | about 102 ms                 |
| none holds          | 165–170 ms            | about 195 ms, 790 kB each    |

Holding pays off where one runtime lives as long as its OS process (stdio)
and costs every connection where runtimes are short-lived (in-process
clients and tests). A shared, reference-counted snapshot per server would
serve both but needs a registry and delayed freeing; it was not built.

Costs accepted:

- Holding puts a new key, which copies the catalog and the node's term
  table once. Freeing erases the key, which makes every process on the node
  check its heap for the old catalog. An endpoint frees only on registry
  changes and at shutdown, and a stdio runtime when its process ends, never
  per request.
- An in-process or `runtime.start` connection copies the called tool into
  each invocation worker; the peak is one tool per concurrent call.
- Registering tools in a tight loop on a live endpoint or stdio server is
  expensive, because each change frees the previous snapshot.
- Tool handlers and context builders stay in `persistent_term` for the
  holder's lifetime. A hot code purge of their module no longer kills or
  waits for the holder, as it would for closures on a process heap; calls
  can fail until the holder restarts (tracked in
  `issues/held-server-snapshots/issues/01-hot-code-purge-leaves-held-tool-closures-stale.md`).
- Registry changes on a live endpoint keep each older snapshot until
  the last request that leased it settles, so a long-lived subscription stream
  keeps its snapshot held until it closes.
