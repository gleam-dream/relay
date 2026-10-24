# Own client header acquisition and subscription opening

<a id="adr-0011"></a>

- The repository owner approved one client request budget covering dynamic header acquisition and transport on 16 October 2026. A blocked callback previously ran synchronously before the HTTP timeout began; an expired absolute deadline was observed only after it returned.
- Request-owned header work changes callback process affinity. Keeping synchronous acquisition would force applications to implement the same cancellation and deadline machinery. The callback returns header values; its temporary process does not become an application resource owner.
- HTTP Gun response bodies belong to the process that opens them. Moving an entire subscription opening into a temporary callback worker would invalidate the body when that worker exited. A responsive request owner supplies cancellation while the caller opens and consumes the body.
- Subscription acknowledgement ends the relative opening budget. Applying that relative budget as an HTTP body deadline would terminate healthy established streams. Explicit absolute deadlines retain their existing stream-lifetime meaning.
- Borrowed HTTP clients remain application-owned. Relative request bounds do not replace a deadline already carried by a borrowed client. Callback exception details are not returned because they may contain credentials.

The standing contract is [client calls and submission evidence](../design/design.typ#client-calls-and-submission-evidence). The separate Oversight `relay_admission` consumer exercises client header acquisition alongside server admission ownership.
