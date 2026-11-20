# Hold server descriptions once in shared storage

<a id="adr-0017"></a>

## Decision

An HTTP endpoint holds its configuration with its current server description
once in `persistent_term`, one snapshot per registry generation. An admitted
request leases a handle to that snapshot; the request owner, the request
runtime and every invocation worker read the server through the handle. A
connection runtime started with `runtime.start` or `runtime.supervised` holds
its own server the same way. A keeper process frees a snapshot when its
holder releases it or exits; an endpoint releases an older generation once no
admitted request leases it.

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
crossings, and every stdio call copied 249 kB into its worker. The copy grew
with the catalog, not with the request, which is the pattern that exhausted
memory in a production service built on JSON Blueprint 2.1.0.

On OTP, a term read from `persistent_term` is a shared literal: neither
spawn nor send copies it. Holding the catalog there makes per-request and
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

Costs accepted: storing or erasing a `persistent_term` value makes the
node check every process for references to the old one, so holding happens
only at startup, on registry changes and at shutdown, never per request.
Registering tools in a tight loop on a live endpoint or runtime is therefore
expensive. Registry changes on a live endpoint keep each older snapshot until
the last request that leased it settles, so a long-lived subscription stream
keeps its snapshot held until it closes.
