#import ".render/designlib.typ": *

#let title = [Relay: typed MCP exchanges]
#let accent = "blue"
#let body = [
  #section(title: "Foundation", lead: "Relay carries MCP meaning and owns protocol execution lifetimes.", body: [
    #goal(title: "Serve and call native application operations")[Expose typed tools, resources, prompts, and completion through MCP server and client operations over stdio and Streamable HTTP. Reuse each tool's definition across declaration, binding, and typed calling.]
    #goal(title: "Retain the complete protocol capability scope")[Support explicit revision strategies, both MCP authorization roles, and independently verifiable extension boundaries. The modern implementation and the retained compatibility obligations are distinguished in the pending ledger.]
    #no-goal(title: "Own business execution or identity providers")[Application effects, retry policy, durable runs, workflow settlement, web login, and general authorization-server operation belong to callers or independently useful libraries. Relay supplies protocol ports.]
    #invariant(title: "Wire ids never own execution", enforcement: "mechanism")[Exchange and invocation identities select authoritative work and response destinations. Repeated JSON-RPC ids cannot merge concurrent work.]
    #invariant(title: "Admission precedes handler work", enforcement: "mechanism")[Protocol validation, endpoint bearer admission when configured, tool visibility and execution permission, and native argument decoding precede the handler's effect. A rejection produces no tool invocation.]
    #invariant(title: "Terminal exchanges suppress subsequent output", enforcement: "mechanism")[Completion and closure consume an exchange in one authoritative reducer history. A late completion or progress report cannot answer a replacement request.]
    #principle(title: "Keep authority with the boundary that can prove it")[Revision codecs own wire meaning; the runtime owns serialized effect interpretation; a token verifier owns token validity; the application owns business policy and effect outcome.]
    #principle(title: "Retain distinct absence and failure meanings")[Omitted fields, explicit null, false hints, tool refusals, input requests, protocol failures, and uncertain delivery retain distinct representations. See #adr(2) and #adr(5).]
  ])

  #pending-ledger(
    pending-entry(title: "Bound admission without changing callback ownership", kind: "ruling", adr: [#adr(8)])[
      Context construction and bearer verification execute synchronously before the HTTP invocation and response budgets start. Admission can retain a request slot outside those budgets. A whole-request deadline requires an explicit process-affinity, cancellation, cleanup, late-success, and capacity-release contract; no correction is approved here.
    ],
    pending-entry(title: "Bind paging and input state to the admitted view", kind: "ruling", adr: [#adr(4)])[
      The implemented cursor authenticates family and offset with the server key; continuation state authenticates the operation family and a nonce, without binding arguments, principal or outstanding response keys. The retained design requires catalog revision, tenant and authorized visible-view binding. Cross-trust-domain grant reuse, anonymous access, and policy changes between rounds need explicit semantics before claiming these stronger guarantees.
    ],
    pending-entry(title: "Broaden dynamic schema interoperability deliberately", kind: "ruling", adr: [#adr(2)])[
      MCP declarations may contain valid JSON Schema outside Blueprint's finite input-contract profile. UnsupportedSchema remains explicit; valid default-open schemas currently expose a Blueprint admission defect. Choosing a broader bounded contract port or an enlarged profile requires separate approval and external peer evidence.
    ],
    pending-entry(title: "Implement retained revision and OAuth strategies", kind: "build", adr: [#adr(1)])[
      Legacy 2025-11-25 sessions and their transport strategy, older retained revisions, client OAuth discovery/registration/PKCE/refresh flows, and selected extensions remain designed scope. Modern readiness never invents a legacy handshake.
    ],
    pending-entry(title: "Complete protocol and public test support", kind: "build", adr: [#adr(7)])[
      Resource-read continuation, an approved typed logging emitter, expanded paired/scripted/fake-clock transport and authorization-server helpers, and independently pinned client/auth/interoperability acceptance remain incomplete. Tasks, Apps, sender constraints, workload identity, target expansion, and release hardening require their scoped requirements and evidence.
    ],
    pending-entry(title: "Verify resource claims at their actual boundaries", kind: "verify", adr: [#adr(3)])[
      Request slots are acquired after Mist reads the bounded body; mounted callers pre-read it themselves. These limits do not establish a bound on incomplete body readers or all network processes. Comprehensive owner-death/process-count evidence, SSE reconnection/resumption where supported, and continuous drift/soak/fuzz coverage remain separate obligations.
    ],
  )

  #section(title: "System at a glance", lead: "One MCP context has separate wire, admission, execution, and application owners.", visual: diagram(
    altitude: "L2", viewpoint: "context-ownership", title: "From native contracts to owned exchanges",
    nodes: (
      (id: "application", label: "Application", sub: "native types, business policy", kind: "external-system"),
      (id: "definition", label: "Definitions and catalog", sub: "tools, resources, prompts", kind: "component", tint: "blue"),
      (id: "admission", label: "HTTP admission", sub: "context, verifier, headers", kind: "component", tint: "blue"),
      (id: "reducer", label: "Revision and reducer", sub: "wire meaning, pure state", kind: "component", tint: "blue"),
      (id: "runtime", label: "Runtime", sub: "one history, handler ownership", kind: "component", tint: "blue"),
      (id: "transport", label: "HTTP / stdio", sub: "framing, stream lifetime", kind: "component", tint: "blue"),
      (id: "client", label: "Client", sub: "views, evidence, continuations", kind: "component", tint: "blue"),
      (id: "peer", label: "MCP peer", kind: "external-system"),
    ),
    edges: (
      (from: "application", to: "definition", relation: "call", label: "binds operations"),
      (from: "application", to: "admission", relation: "call", label: "supplies context and verifier"),
      (from: "definition", to: "reducer", relation: "dependency", label: "declaration and dispatch"),
      (from: "admission", to: "runtime", relation: "dataflow", label: "admitted context"),
      (from: "runtime", to: "reducer", relation: "call", label: "serial transitions"),
      (from: "runtime", to: "application", relation: "call", label: "isolated handler"),
      (from: "transport", to: "runtime", relation: "call", label: "frame / close"),
      (from: "peer", to: "transport", relation: "dataflow", label: "requests"),
      (from: "client", to: "peer", relation: "call", label: "typed or discovered call"),
    ),
    caption: [Blueprint owns application codecs/contracts, HTTP Gun owns outbound HTTP, and Sinal owns observation delivery. Relay has no dependency on Fabric, Saga, or Warden.],
  ), body: [
    #points(
      [The #term("term-server") is immutable. An #term("term-endpoint") or #term("term-runtime") owns the live registry, while a copied description has no authority to mutate running work.],
      [Modern HTTP creates a runtime per request from the endpoint's current server snapshot. Stdio and in-process clients retain one connection runtime. The #term("term-reducer") consumes events in that owner's serialized history.],
      [Relay is one Erlang distribution with internal protocol, schema, transport, and foreign-boundary modules. A pure transition boundary is retained; JavaScript runtime support is not implemented. See #adr(1).],
    )
    #md-table(3, (
      [*Decision*], [*Authority*], [*Outcome and boundary*],
      [Wire revision], [Frozen MCP schema and requirements], [Admission never infers compatibility from a malformed response.],
      [Tool input/output], [Definition codecs], [Erasure retains closures; it does not expose Dynamic to ordinary callers.],
      [Bearer validity], [Configured verifier], [Attestation asserted by trusted adapter; Relay checks resource/scopes.],
      [Execution history], [Runtime actor], [One interpreter starts each admitted invocation; copied pure values do not prove exactly-once effects.],
      [Business retry and durability], [Application], [Submission evidence and cancellation never establish rollback.],
    ))
  ])

  #section(title: "Domain model", lead: "Exchange ownership, handler execution, and connection lifetime are independent state axes.", body: [
    #points([A #term("term-definition") may create several #term("term-bound-tool") values. Each #term("term-exchange") keeps a fresh response destination; each #term("term-invocation") keeps its own handler identity even when a #term("term-request-id") repeats.])
    #entity(title: "Definition", description: [A tool's native contract reused on both sides of MCP.], kind: "value-object", owner: "tool admission", lifecycle: "immutable", domain: "MCP", tint: "blue")[
      #attribute(name: "Contract", type: [name × Codec(input) × output mode], provenance: "authored")[Structured output retains a codec and schema; content-only output retains no output codec.]
      #attribute(name: "Declaration", type: [schemas, annotations, icons, metadata], provenance: "derived")[Derived from admitted codecs and the caller's independent optional settings.]
      #relates(cardinality: "1 : 0..n")[One definition may bind several handlers or serve typed calls without changing native type agreement.]
    ]
    #state-type(id: "exchange-phase", title: "Exchange phase", variants: ("Vacant", "Active", "Stream", "Done"))
    #entity(id: "exchange", title: "Exchange", description: [An inbound frame's authoritative destination, independent of its wire id.], kind: "entity", owner: "reducer history", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(name: "Identity", type: [opaque ExchangeId], provenance: "derived")[The transport allocates a fresh node-unique identity before parsing.]
      #attribute(id: "phase", name: "Phase", type: [Exchange phase], provenance: "derived", state-type: "exchange-phase", state-machine: "exchange-life")[Vacant means no retained record; Done is a retained terminal record.]
      #attribute(name: "Routing", type: [RequestId × optional progress token × optional InvocationId], provenance: "derived")[Active retains invocation and latest accepted progress; Stream retains a listen request.]
      #relates(cardinality: "1 : 0..1")[One exchange owns at most one handler invocation or one subscription stream.]
    ]
    #state-machine(id: "exchange-life", subject: "exchange", state-field: "phase", state-type: "exchange-phase", title: "One response destination", initial: "Vacant", accepting: ("Done",), states: ("Vacant", "Active", "Stream", "Done"), transitions: (
      ("Vacant", "Active", "admit handler work"), ("Vacant", "Stream", "admit listen"), ("Vacant", "Done", "immediate response or close before admission"),
      ("Active", "Done", "finish / crash / timeout / close"), ("Stream", "Done", "end / cancellation / peer close"),
      ("Done", "Done", "suppress replay and late input"), ("Done", "Vacant", "prune terminal retention"),
    ), caption: [Fresh identity is mandatory even after retention is pruned. A pruned id is not reusable authority.])
    #state-type(id: "worker-phase", title: "Worker phase", variants: ("Pending", "Running", "Cancelling", "Exited"))
    #entity(id: "invocation", title: "Invocation", description: [One admitted native handler work item and its owned worker.], kind: "entity", owner: "runtime", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(name: "Identity and work", type: [InvocationId × exchange × selected work × context], provenance: "derived")[Retains method, name, metadata, arguments, input responses, and correlation without reusing the client's id.]
      #attribute(id: "phase", name: "Worker phase", type: [Worker phase], provenance: "derived", state-type: "worker-phase", state-machine: "worker-life")[A terminal exchange may coexist with a Cancelling worker during its cleanup grace.]
      #relates(cardinality: "n : 1")[Every invocation returns to exactly one runtime history and one retained exchange.]
    ]
    #state-machine(id: "worker-life", subject: "invocation", state-field: "phase", state-type: "worker-phase", title: "Handler execution and cleanup", initial: "Pending", accepting: ("Exited",), states: ("Pending", "Running", "Cancelling", "Exited"), transitions: (
      ("Pending", "Running", "interpret Start"), ("Pending", "Exited", "late Start meets tombstone"),
      ("Running", "Exited", "return or crash"), ("Running", "Cancelling", "disconnect / cancellation / timeout / owner exit"),
      ("Cancelling", "Exited", "cooperative return or grace kill"),
    ), caption: [Cancellation stops publication immediately; cleanup completion is a separate observation.])
    #entity(title: "Server catalog", description: [The invariant owner of declaration and handler agreement.], kind: "aggregate", owner: "server description / live endpoint", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(name: "Services", type: [tools × resources × prompts × optional completion], provenance: "authored")[Tools have unique names; listings retain registration order.]
      #attribute(name: "Signing key and generation", type: [random key × monotonic registry generation], provenance: "derived")[The immutable description retains the key across request runtimes; the endpoint owns generation changes.]
      #relates(cardinality: "1 : 0..n")[Many request snapshots and streams refer to one current endpoint catalog.]
    ]
    #entity(title: "Grant", description: [Accepted endpoint authority over one resource and native principal.], kind: "value-object", owner: "resource admission", lifecycle: "immutable", domain: "MCP", tint: "blue")[
      #attribute(name: "Principal and authority", type: [principal × ProtectedResource × List(Scope)], provenance: "derived")[Actual accepted claims, including scopes beyond endpoint requirements, survive admission.]
      #relates(cardinality: "n : 1")[An admitted HTTP request uses the endpoint's configured Protection; arbitrary grant reuse is not a public protected-registry mechanism.]
    ]
    #md-table(3, (
      [*Products, sums and refinements*], [*Representations*], [*Preserved meaning*],
      [Request id], [StringId / IntegerId], [String 1 and integer 1 remain distinct; ids may repeat.],
      [Reply / ToolResult], [complete / input round; Succeeded / ToolFailed / InputRequired], [Application refusal completes an exchange but does not prove no effect.],
      [Structured discovery], [Option(Value)], [None is absence; Some(Null) is present null.],
      [Content], [text / image / audio / link / embedded resource], [Bytes remain native; base64 appears only in the codec.],
      [Application annotations], [Option(Bool) hints and optional generic annotations], [Omission differs from False; hints are untrusted policy evidence.],
      [Failures], [Reason × Correlation; Kind; Evidence], [Opaque context does not change detailed reason matches.],
      [Validated values], [name 1–128 permitted ASCII; resource absolute HTTP(S) without fragment; nonempty scope], [Admission validates the boundary; it does not normalize resource aliases or scope case.],
    ))
    #points([There is no persistent storage aggregate in Relay. Tombstones are node-local suppression records; receipts, durable idempotency, and retained business outcomes belong to applications. Commands and effects are detailed below; observation events report completed protocol transitions.])
  ])

  #section(title: "Protocol and schema boundaries", lead: "Revision codecs validate envelopes independently of application schema admission.", body: [
    #answers(title: "Modern wire codec", responsibility: [Parse and classify revision-specific messages and encode exact results and errors.], interface: [Internal JSON-RPC and v2026_07_28 admission/encoding functions; public protocol data in content, declarations, and tool input methods.], interactions: [Receives bounded bytes; supplies admitted request metadata and checked Blueprint values to reducer dispatch.], invariants: [Unambiguous protocol members, trustworthy ids, required metadata, matching routing headers, and distinct envelope families.], failure: [Parse, invalid request, invalid parameters, unknown method, unsupported version, and routing disagreement remain distinct; no handler starts on refusal.])
    #md-table(3, (
      [*Contract*], [*2026-07-28*], [*Retained 2025-11-25 strategy*],
      [Readiness], [Self-contained request metadata; discover optional for caller], [initialize → AwaitingInitialized → initialized → Ready],
      [HTTP], [One POST; no session GET/DELETE or Mcp-Session-Id], [POST JSON/SSE, GET notifications, DELETE termination, session registry],
      [Headers], [MCP-Protocol-Version, Mcp-Method, tool Mcp-Name agree with body], [Negotiated revision and session-aware header validation],
      [Result], [Complete includes resultType, including isError results], [Legacy result codec omits resultType],
      [Cancellation], [HTTP close; stdio notifications/cancelled], [Revision-scoped restrictions including initialize cancellation],
      [Logging and ping], [Per-request logLevel metadata; no legacy setLevel or ping route], [Legacy methods only where its schema requires them],
    ))
    #points(
      [Modern `_meta` carries protocol version and configured client capabilities. Unsupported versions return the pinned -32022 outcome with supported revisions. Omitted tool arguments become an empty object; supplied non-objects fail before domain decoding.],
      [A notification has no ordinary JSON-RPC response. Accepted HTTP notifications receive 202 with an empty body; valid unsupported notifications and inbound responses must not become invocations. Parse errors omit an untrustworthy wire id while retaining the exchange destination.],
      [Modern cache fields are private with zero TTL in the implemented families. This does not establish cache revision or conditional ownership semantics. Required fields are validated against the frozen fixture rather than inherited from older SDK shapes.],
      [The #term("term-protocol-schema") in test fixtures is authority for wire shapes. A tool inputSchema/outputSchema is an application JSON Schema document represented as an exact Blueprint Value. Loading an #term("term-input-contract") admits Blueprint's finite profile; provider schema lowering belongs to LLM Wire adapters, outside Relay.],
      [Local input admission accepts Blueprint ObjectSchema and UnionSchema; OtherSchema requires an explicit object declaration; AnySchema fails closed. Output admission requires a schema document whose JSON representation is an object, not an object-shaped application output. This permits string and other structured output codecs.],
      [Remote declarations preserve schema documents and metadata before optional input_contract loading. A valid MCP declaration need not have a locally admitted Blueprint contract; unsupported features remain an explicit error rather than silently closing or weakening the schema. See #adr(1), #adr(2), and #adr(7).],
    )
    #behavior(title: "Reject a mismatched modern request before dispatch", area: "Wire admission", level: "interface")[
      #given[A POST claims a different version, method, or tool name in its routing headers and body.]
      #when[The server receives the MCP request.]
      #then[The request receives the corresponding refusal without running its tool handler.]
    ]
    #behavior(title: "Retain complete tool failures as protocol results", area: "Result semantics", level: "interface")[
      #given[A handler returns a safe application ToolError.]
      #when[The modern call finishes.]
      #then[The client receives ToolFailed from an isError result with resultType complete.]
      #then[Submission evidence is Completed; the application's effect outcome remains its own contract.]
    ]
  ])

  #section(title: "Definitions and service catalog", lead: "One retained contract drives declaration and dispatch while caller records remain native.", body: [
    #answers(title: "Tool construction and binding", responsibility: [Admit a name and codec-derived declarations; bind native handlers before erasure.], interface: [define / try_define; define_content / try_define_content; handle, handle_with_error_renderer, handle_call; independent metadata setters.], interactions: [Blueprint owns schema/codecs; bound tools enter server.new or live register_tool; client.call reuses a Definition.], invariants: [Input schema object root; output schema availability for structured tools; duplicate names rejected; no private generic errors disclosed by ordinary handle.], failure: [Source-definition mistakes panic with the offending name; runtime admission returns DefineError; ordinary handler errors become a generic safe ToolError.])
    #points(
      [Name admission permits ASCII letters, digits, period, underscore, hyphen and slash with length 1–128. Static server.new rejects duplicate names; runtime register_tool returns DuplicateTool. Unregistering an absent name is a no-op.],
      [with_input_schema publishes an explicit JSON object document in place of the codec-derived input schema. It does not replace the retained native codec, which still decodes every call. A non-object schema document is a source-definition panic; truthful agreement between an override and actual accepted inputs belongs to its author.],
      [handle accepts the caller's arbitrary error type and hides its details. The explicit renderer chooses safe content; handle_call receives Call(context) and returns complete, explicit content, metadata, or input-required requests. Context, progress, cancellation, client info, correlation and ids remain per invocation.],
      [A structured success encodes the native output and generates a text mirror unless explicit content replaces it. complete_with_meta replaces metadata on generated content blocks. Invalid output encoding and crashes become sanitized protocol failures; they never manufacture successful data.],
      [Annotations retain independent optional fields, including absent versus false. readOnlyHint and idempotentHint describe remote claims; applications choose whether to trust them when deciding uncertain-effect handling.],
    )
    #md-table(3, (
      [*Service*], [*Interface and interaction*], [*Failure and invariant*],
      [Resources], [static / template / try_template / template_with_matcher; list/read; native text/blob contents], [One simple variable per slash segment, including suffix/prefix; unsupported syntax requires explicit matcher; private read errors become resource-not-found.],
      [Prompts], [prompt / prompt_call with named string arguments; list/get; role and content messages], [Required arguments validated; private errors become invalid params; input rounds retain Call context.],
      [Completion], [completion receives prompt/template reference, argument name/value and other arguments], [Private error becomes internal error; output limited to 100 values with total and has_more.],
      [Content], [text/image/audio/resource link/embedded resource; annotations, icons, meta; text_of], [Binary bytes preserved; text_of intentionally projects text only and joins text blocks.],
      [Paging], [Deterministic catalog order, signed family/offset cursor, client all-page traversal], [Forged/cross-family cursors fail; authorized-view/revision binding remains a ruling.],
      [Registry updates], [server changes immutable description; endpoint/runtime register_tool changes live owner], [Successful changes increment generation and notify active relevant streams; absent removals and failed additions do not invent changes.],
    ))
    #behavior(title: "Re-evaluate visibility on named calls", area: "Tool access", level: "interface")[
      #given[A tool was listed for an earlier application context but is now hidden or not callable.]
      #when[The client names that tool in a new call.]
      #then[The client receives the same inaccessible protocol outcome as an unknown name.]
      #then[Neither argument decoding nor the handler runs.]
    ]
    #behavior(title: "Bind custom resource matching explicitly", area: "Service extension", level: "interface")[
      #given[A resource family uses syntax beyond one simple variable per segment.]
      #when[The application uses the built-in runtime template constructor.]
      #then[It receives UnsupportedTemplateSyntax.]
      #then[Using a caller matcher preserves the advertised template and the caller's URI-recognition policy.]
    ]
    #points([Current interfaces and rationale are recorded in #adr(2). Access policy is per request; its evaluation is not atomic with an application's later data changes or handler effects.])
  ])

  #section(title: "Reducer and runtime ownership", lead: "A pure state transition emits work; one actor decides when that work runs.", body: [
    #answers(title: "Reducer", responsibility: [Maintain exchange, invocation, subscription, and catalog state for one authoritative history.], interface: [init, step, perform; Received, Finished, Progressed, Crashed, TimedOut, ExchangeClosed, Notify, RegisterTool, UnregisterTool, EndStreams.], interactions: [Produces Write, Start, Cancel, Close, and Admitted effects; perform runs outside step in the calling worker.], invariants: [Every effect names an exchange or invocation; repeated admission and terminal input suppress output; progress requires the retained token and increasing nonnegative progress.], failure: [Wire errors return immediate responses; unknown/late completions do nothing; copied state and invocations require an owner rather than granting exclusive execution.])
    #answers(title: "Runtime actor", responsibility: [Serialize reducer commands, account for live capacity, isolate handlers, and own cancellation cleanup.], interface: [start / supervised, send_frame, exchange_closed, notify, register/unregister, close, stop; OutputWrite / OutputClose sink.], interactions: [Unlinked monitored workers perform handlers; sink delivery is acknowledged; lifecycle telemetry reports transitions.], invariants: [Duplicate exchange admission consumes no extra slot; bounded frames/depth/exchanges/tombstones; no late Start after cancellation tombstone; runtime remains alive until cancelled workers exit.], failure: [FrameTooLarge, FrameTooDeep, TooManyLiveExchanges, RuntimeStopped are typed admission failures; worker crash/timeout is sanitized on its own exchange; sink error closes that exchange.])
    #md-table(3, (
      [*Runtime setting*], [*Default*], [*Boundary*],
      [Live exchanges], [100], [Admission refuses TooManyLiveExchanges before a new worker. Duplicate admission consumes no slot.],
      [Frame / depth], [1 MiB / 64], [FrameTooLarge / FrameTooDeep before reducer admission.],
      [Invocation / cancellation], [30 s / 5 s grace], [Timeout closes publication; grace bounds the runtime-owned handler's cleanup interval.],
      [Invocation tombstones], [60 s / 10,000], [Late starts are suppressed within retained identity history; fresh ids remain mandatory after pruning.],
    ))
    #md-table(3, (
      [*Effect timing*], [*Owner action*], [*Observable guarantee*],
      [Received → admitted], [Reduce bounded validated bytes with explicit context], [Admitted observation follows protocol acceptance; refusal starts no worker.],
      [Start], [Retain worker ownership and start handler once], [Invocation.started identifies execution; no exactly-once business-effect promise.],
      [Progressed], [Validate active token, monotonic progress; wait for sink acknowledgement], [Backpressure reaches the producer; late or invalid reports are dropped.],
      [Finished / crash / timeout], [Produce one terminal output and close exchange], [Private crash details stay off wire; later completions cannot answer again.],
      [Cancel], [Signal handler selector; schedule grace kill], [Wire output stops; handler may clean downstream work during grace.],
      [Stop / owner exit], [Cancel all active work and retain cleanup ownership], [No unowned cancelled handler is declared cleaned before it exits or is killed.],
    ))
    #points(
      [perform must run in the process addressed by signal_cancelled. Custom interpreters own scheduling, serialization, output acknowledgements, cancellation delivery and retention. A pure transition library cannot enforce these obligations for an arbitrary interpreter.],
      [Reducer closed exchange records are bounded at 10,000 and prune oldest records to three quarters when exceeded. Each runtime invocation #term("term-tombstone") is retained for 60 seconds, at most 10,000 by default. Fresh node-unique identities prevent pruned records from aliasing new work.],
      [Every cancellation path signals first and preserves a default 5-second #term("term-cancellation-grace"), including timeout, close, stop, disconnect, stdio cancellation, and owner exit. The handler owns cancellation of effects it started elsewhere. Killing a worker is neither compensation nor proof a remote effect did not happen. See #adr(3).],
    )
    #behavior(title: "A failed sink closes only its exchange", area: "Runtime output", level: "interface")[
      #given[A runtime serves several exchanges and its output sink cannot write one exchange.]
      #when[That sink returns an error.]
      #then[The affected exchange closes and its invocation receives cancellation.]
      #then[Other exchanges retain their own destinations and lifetimes.]
    ]
    #behavior(title: "A late completion cannot replace live work", area: "Runtime races", level: "interface")[
      #given[An old exchange closed and a new exchange reused the same wire request id.]
      #when[The old invocation reports progress or completion.]
      #then[No output is written for the old invocation and the new exchange remains unaffected.]
    ]
  ])

  #section(title: "HTTP endpoint and limits", lead: "Buffered mounting, streaming ownership, and admission budgets have different guarantees.", visual: sequence(
    title: "Protected request timing", participants: (
      (id: "peer", label: "Peer", shape: "participant"), (id: "mist", label: "HTTP body reader", shape: "boundary"),
      (id: "endpoint", label: "Endpoint / request process", shape: "control"), (id: "callback", label: "Verifier and context", shape: "participant"),
      (id: "runtime", label: "Runtime / handler", shape: "control"),
    ), steps: (
      seq-msg("peer", "mist", "POST bounded body"), seq-msg("mist", "endpoint", "acquire request slot; validate headers"),
      seq-msg("endpoint", "callback", "synchronous admission", activate: true), seq-note("callback", [Outside request_timeout supervision], side: "right"),
      seq-msg("callback", "endpoint", "grant and native context", dashed: true, deactivate: true),
      seq-msg("endpoint", "runtime", "start invocation and response budgets", activate: true),
      seq-msg("runtime", "peer", "JSON or SSE; progress; final result", dashed: true),
      seq-msg("peer", "runtime", "disconnect signals cancellation", deactivate: true),
    ), caption: [This is the implemented ordering. Whole-request deadline and callback process-affinity corrections remain unresolved in #adr(8).],
  ), body: [
    #answers(title: "Endpoint owner", responsibility: [Own current registry, admission slots, streams, optional listener and shutdown ordering.], interface: [new / new_with_context / new_protected, setters, handler, handle, mist_handler, start, supervised, stop; live registration and notify.], interactions: [Mist owns socket reads/writes; the endpoint leases a server snapshot, builds context, then creates request runtime/broker; application router owns mounted endpoint lifetime.], invariants: [Validate completed config before binding; loopback default; nonloopback unprotected bind requires explicit opt-in; header/media/Host/Origin validation and byte/depth limits precede protocol work.], failure: [Typed startup settings/actor/listener failures; HTTP rejections with telemetry; capacity 503; body 413; buffered listen 406; response wait failure 504.])
    #state-type(id: "endpoint-phase", title: "Endpoint phase", variants: ("Configured", "Running", "Stopping", "Stopped", "Failed"))
    #entity(id: "endpoint", title: "Endpoint lifetime", description: [The actor and optional linked listener that own admitted HTTP requests.], kind: "aggregate", owner: "endpoint caller", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(id: "phase", name: "Phase", type: [Endpoint phase], provenance: "derived", state-type: "endpoint-phase", state-machine: "endpoint-life")[Running preserves unexpected listener failure propagation; intentional shutdown disconnects that link before termination.]
      #relates(cardinality: "1 : 0..1")[A mounted endpoint has no Relay listener; a started endpoint owns one listener.]
    ]
    #state-machine(id: "endpoint-life", subject: "endpoint", state-field: "phase", state-type: "endpoint-phase", title: "Listener ownership", initial: "Configured", accepting: ("Stopped", "Failed"), states: ("Configured", "Running", "Stopping", "Stopped", "Failed"), transitions: (
      ("Configured", "Running", "validated start / handler"), ("Configured", "Failed", "startup refused"),
      ("Running", "Stopping", "intentional stop; unlink owned listener"), ("Stopping", "Stopped", "cancel work and terminate listener"),
      ("Running", "Failed", "unexpected linked listener failure"),
    ), caption: [Unlinking a running listener or ignoring all linked exits would break ownership; #adr(6) records the intentional-shutdown correction.])
    #md-table(3, (
      [*Limit or policy*], [*Default / refusal*], [*Application point*],
      [Bind and protection], [127.0.0.1, ephemeral; unprotected nonloopback start fails], [Validated before listener startup; allow_unauthenticated is explicit caller policy.],
      [Body and JSON depth], [1 MiB → 413; depth 64 → 400], [Mist bounded reader before slot; endpoint body check before context; depth before reducer parse. Mounted body allocation belongs to host.],
      [Request slots and listen streams], [1,024 and 64 → 503], [Leased admitted requests/streams; does not count all incomplete network body readers.],
      [Response budget], [1 MiB response or cumulative stream event bytes], [Broker enforces event output budget and acknowledged delivery; existing allocations are not erased by refusal.],
      [Invocation / response wait], [30 s], [Begins after context and bearer callback; response collection and stream write waits have their own timing.],
      [Cancellation and keepalive], [5 s grace; 15 s SSE keepalive], [Disconnect suppresses output and signals worker; keepalive is transport liveness.],
      [Host and Origin], [Loopback names / bind host and configured origins], [Case-insensitive header names; rejection precedes callback; missing Origin is permitted by current policy.],
    ))
    #points(
      [handle consumes Request(BitArray) and returns buffered Response(BytesTree). It drops progress, cannot observe peer disconnect, and rejects subscriptions/listen with 406. mist_handler, start, and supervised retain streaming, keepalive and disconnect cancellation.],
      [Context and verifier closures execute in the serving request process. A blocking callback occupies its admitted slot and can delay observing closure. Its own network/database timeout and owned cleanup remain the caller's responsibility under the current implementation; the false whole-request claim is a design gap, not a repaired runtime guarantee.],
      [Modern MCP accepts POST only; protected-resource metadata has a separate GET path. No modern GET notification endpoint, DELETE session termination, or protocol session is added by this metadata route.],
      [Optional FFI helpers inspect Mist's Connection record to set a send timeout and observe buffered connection closure. They fall back on unfamiliar shapes; Mist upgrades require the real disconnect tests and record-contract check. See #adr(3).],
    )
    #behavior(title: "Buffered mounting refuses listen streams", area: "HTTP mounting", level: "interface")[
      #given[An application mounted the framework-neutral buffered handler.]
      #when[A client requests subscriptions/listen.]
      #then[The response is 406; ordinary requests remain buffered and emit no progress.]
    ]
    #behavior(title: "Protected context runs before invocation supervision", area: "HTTP admission timing", level: "interface")[
      #given[A configured verifier or context callback remains blocked beyond the request timeout.]
      #when[The callback later succeeds under the current implementation.]
      #then[The invocation may still start and return success because its budget begins after the callback.]
      #then[The request timeout setting has not bounded the callback's lifetime.]
    ]
  ])

  #section(title: "Subscriptions and live registry changes", lead: "Acknowledgement follows successful owner registration, while churn history stays unretained.", body: [
    #points([Each #term("term-subscription") has an independent owner and cancellation destination. A listing #term("term-cursor") selects a position, while endpoint generation orders live catalog reconciliation. Neither is business identity.])
    #answers(title: "Endpoint stream registration", responsibility: [Coordinate current catalog, subscription capability/filter and publication of the initial stream frames.], interface: [subscriptions.listen through reducer, endpoint stream attach/reconcile, notify, register/unregister and end_streams.], interactions: [The lease carries server snapshot and generation; the endpoint serializes activation and reconciles changed snapshots into request runtimes before acknowledgement release.], invariants: [Same-name replacement updates handler and metadata; no lifetime change journal; no acknowledged ghost stream; unsupported notification kinds are omitted.], failure: [Owner death, timeout, failed reconciliation or writer failure tears down runtime/broker/stream and queues unregister if admission may have happened.])
    #state-type(id: "subscription-phase", title: "Subscription phase", variants: ("Pending", "Active", "Closed"))
    #entity(id: "subscription", title: "Subscription", description: [An acknowledged notification filter tied to one listen exchange.], kind: "entity", owner: "endpoint/runtime and client stream owner", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(id: "phase", name: "Phase", type: [Subscription phase], provenance: "derived", state-type: "subscription-phase", state-machine: "subscription-life")[Pending bytes are held until owner registration succeeds.]
      #attribute(name: "Filter", type: [resource-updated URI / tools/resource/prompt list-change kinds], provenance: "authored")[The acknowledgement retains only offered kinds, including tools-list change for an empty dynamic registry.]
      #relates(cardinality: "n : 1")[Many subscriptions share one stdio child or current HTTP endpoint catalog.]
    ]
    #state-machine(id: "subscription-life", subject: "subscription", state-field: "phase", state-type: "subscription-phase", title: "No acknowledgement before activation", initial: "Pending", accepting: ("Closed",), states: ("Pending", "Active", "Closed"), transitions: (
      ("Pending", "Active", "register / reconcile then release acknowledgement"), ("Pending", "Closed", "failure with unregister cleanup"),
      ("Active", "Closed", "client close / end streams / disconnect / owner exit"), ("Closed", "Closed", "idempotent close"),
    ))
    #points(
      [Every accepted catalog mutation increments generation. A changed snapshot reconciles the complete current catalog and produces a tools-list-change notification before activation acknowledgement; reconciliation cost depends on snapshot/current size rather than prior churn.],
      [Stdio subscription ids correlate events within the child owner. FIFO queues preserve notifications for other subscriptions across a timed-out read; closing one subscription sends its cancellation, marks it closed and discards only its events. The shared child remains usable.],
      [Pending stdio frames and notifications have a 256-frame bound; overflow closes the owned child before evicting its handle. This is a retained-data count bound, alongside frame byte bounds, rather than a universal allocation or stream-delivery guarantee. See #adr(6).],
    )
    #behavior(title: "Same-name replacement becomes current before acknowledgement", area: "Registry races", level: "interface")[
      #given[A pending stream's catalog snapshot contains a tool removed and re-registered under the same name.]
      #when[The server activates that stream.]
      #then[The stream observes tools-list change and subsequent requests use replacement metadata and handler.]
    ]
    #behavior(title: "Timeout preserves another stdio subscription's events", area: "Subscription reads", level: "interface")[
      #given[Events for subscription B arrive while a read waits on subscription A.]
      #when[A's read times out.]
      #then[B's events remain available in arrival order and the child remains owned.]
    ]
  ])

  #section(title: "Stdio transport", lead: "A trusted parent owns the child boundary and one actor serializes pipe traffic.", body: [
    #answers(title: "Server stdio adapter", responsibility: [Frame bounded newline JSON-RPC and serialize stdout without nonprotocol noise.], interface: [serve blocks main; serve_with config sets chunk size and runtime limits.], interactions: [Binary stdin reader, incremental framer, serialized writer and runtime; EOF and asynchronous writer error reach the serving owner.], invariants: [4 KiB reads by default; LF or CRLF framing; UTF-8 may split between byte chunks; stdout exclusively protocol; oversized tail discarded until newline.], failure: [Invalid settings, ReadFailed, StdoutBroken, StartupFailed and InvalidTrailingData are typed; broken stdout terminates even with idle stdin; shutdown retains cleanup ownership.])
    #answers(title: "Client child owner", responsibility: [Launch executable directly, own its port, and serialize requests and subscription reads.], interface: [client.stdio config / connect; internal request, subscribe, next and cancellation protocol.], interactions: [One actor retains child, framer, FIFO frames/notifications and closed subscription ids; outer client polls cancellation and budgets.], invariants: [No shell fallback; command closure avoids accidental inspection; stderr isolated; reply ids correlated; unrelated responses fail; pending and buffered limits enforced.], failure: [Child exit, malformed frame, timeout, cancellation, client close, oversize and overload become typed client reasons/evidence; terminal errors close port before clearing state.])
    #points(
      [Stdio provides no bearer authorization. Its trust boundary is the parent process and launched executable; metadata or a caller-supplied principal does not supply transport authentication.],
      [Cancelling one active stdio call sends notifications/cancelled. Closing the client closes its owned child and in-flight waits; repeated or concurrent close observes the owner via a monitor rather than treating dead-owner acknowledgement as success work.],
      [EOF in the middle of a nonterminated frame returns trailing-data failure. Idle broken output and child/owner death require asynchronous lifecycle tests; line parsing alone cannot prove cleanup.],
      [Legacy retained stdio shutdown and reconnect behaviors require their own strategy and tests. Existing bounded frames and child ownership do not establish legacy session conformance. See #adr(3) and #adr(7).],
    )
    #behavior(title: "Stdio overflow closes its child before eviction", area: "Child lifetime", level: "interface")[
      #given[A child sends more retained frames than the client permits.]
      #when[The owner detects overflow.]
      #then[The child is closed and subsequent calls fail as a terminal connection.]
    ]
  ])

  #section(title: "Client calls and submission evidence", lead: "Client views share a connection while deadlines, correlation and cancellation remain explicit.", body: [
    #answers(title: "Client configuration and connection", responsibility: [Validate target/settings, own resources it creates, and keep caller-owned HTTP resources distinct.], interface: [http(url), stdio(executable,args), in_process; pure setters; connect; close; with_http_client injection.], interactions: [HTTP Gun provides transport, TLS, pool and cancellation; stdio owns child; in-process owns runtime; immutable views share the peer.], invariants: [Validation precedes connection; plaintext headers off loopback require explicit opt-in; absolute HTTP(S) URL excludes userinfo/query/fragment and invalid escapes; no automatic retry.], failure: [InvalidConfig, ConnectFailed and Refused occur before request delivery; setup errors have a fresh correlation no server saw.])
    #answers(title: "Calls, lists and continuations", responsibility: [Encode arguments, correlate responses, preserve typed protocol outcomes, bound traversal and retain originating continuation.], interface: [call, call_discovered, discover, list services, read_resource, get_prompt, complete, listen/next/close_subscription, resume; list_raw / call_raw; per-client deadline/cancellation/correlation/key views.], interactions: [Definition output codec decodes native values; discovered calls preserve optional exact structured Value and media; request metadata advertises only configured input methods.], invariants: [One response id must match request; response/version/size validation; each continuation retains original client/name/arguments/state; supplied responses cover every request key once with object values.], failure: [Opaque Error retains Reason and Correlation; stable Kind/Evidence classify without diagnostic parsing; malformed or oversized response does not establish application outcome.])
    #md-table(3, (
      [*Client setting*], [*Default*], [*Boundary*],
      [Connect / request timeout], [10 s / 30 s], [Connection startup and individual request; absolute deadline may shorten request budget.],
      [Response bytes], [1 MiB], [ResponseTooLarge retains delivery evidence rather than manufacturing a tool outcome.],
      [All-page listings], [256 pages / 10,000 items], [ListingLimitExceeded; a repeated cursor is MalformedResponse.],
      [Stdio pending calls], [64], [TooManyPendingCalls before enqueueing additional work.],
      [Advertised input methods], [None], [Explicit configuration opts into Elicitation, Sampling or Roots.],
    ))
    #md-table(3, (
      [*Control / result*], [*Contract*], [*Decision left to caller*],
      [Timeout and deadline], [30 s per request; absolute deadline view shares a total budget and may shorten it], [Multi-page traversal otherwise resets request timeout per page; choose total budget explicitly.],
      [Cancellation], [HTTP closes that request connection; stdio sends notification; in-process signals handler], [Handler cleanup and external effect reconciliation remain separate.],
      [Client close], [Owned peer cancels in-flight calls; injected HTTP Gun remains running and calls may finish], [Use per-call cancellation to stop work on the shared HTTP client.],
      [ToolResult], [Succeeded(output,content), ToolFailed(content,structured), InputRequired(requests,state,continuation)], [Continue interaction or choose lossy output projection.],
      [NotSent], [Configuration, pre-send refusal, invalid input, overload; no request sent], [Retry only within caller policy and remaining budget.],
      [MaybeSent], [Lost/oversized/malformed response or in-flight timeout/cancellation], [Mutating work may have happened; use principal+key receipts or reconciliation.],
      [Completed], [HTTP status / RPC answer / tool result / input request observed], [Completion is exchange evidence; tool failure can follow effects.],
      [Output projection], [require retains transport error and classifies refusal/needs-input; require_discovered uses actual presence], [InputRequired projection discards the continuation deliberately; text projection discards nontext media.],
    ))
    #md-table(3, (
      [*Detailed Reason*], [*Kind*], [*Evidence / retained payload*],
      [InvalidConfig], [Configuration], [NotSent; invalid ConfigField.],
      [ConnectFailed / Refused], [Unreachable], [NotSent; failed establishment / HTTP destination policy.],
      [TimedOut / Cancelled / ConnectionClosed], [Timeout / Cancellation / Unreachable], [Explicit Evidence argument records whether submission may have occurred.],
      [TooManyPendingCalls], [Overloaded], [NotSent; configured pending-call limit.],
      [ResponseTooLarge], [TooLarge], [MaybeSent; response byte limit.],
      [HttpStatus], [Rejected], [Completed; status and optional WWW-Authenticate challenge.],
      [RpcError], [Protocol], [Completed; code, message and optional exact data.],
      [MalformedResponse], [Protocol], [MaybeSent; diagnostic detail for logs.],
      [UnsupportedVersion / UnsupportedInputRequest], [Protocol], [Completed; supported revisions / unsupported requested method.],
      [InvalidArguments / InvalidInputResponses], [InvalidInput], [NotSent; arguments diagnostic / exact one-object-per-request-key failure.],
      [ListingLimitExceeded], [TooLarge], [Completed; page or item limit encountered after a listing response.],
    ))
    #points(
      [list_raw preserves exact item values while retaining the same page/item bounds and repeated-cursor protection. call_raw returns the exact result value through the same request validation, evidence and controls; tools/call, prompts/get and resources/read require a routing name, while other methods reject one. Raw access does not bypass revision or transport admission.],
      [Error Kind remains closed: Configuration, Unreachable, Timeout, Cancellation, Overloaded, Rejected, Protocol, InvalidInput, TooLarge. Detailed Reason includes status and WWW-Authenticate, RPC code/message/data, version, input and limit detail, and delivery evidence. Log describe_error with error_correlation; never branch on prose.],
      [is_retryable is an advisory classification, not a retry loop or effect proof. NotSent unreachable/timeout and overload can be retried; MaybeSent unreachable/timeout requires application-approved idempotence; 429/503 retain explicit HTTP status. Read-only hints from untrusted peers do not supply that approval.],
      [Input methods Elicitation, Sampling and Roots are configured explicitly; no responders are advertised by default. Handler requests are filtered to client capability; unsupported incoming methods fail instead of automatically executing local capabilities. A #term("term-continuation") retains its origin rather than retargeting subsequent answers.],
      [Connection copies share lifetime. Views attach an absolute deadline, cancellation token, correlation or idempotency key without creating resources. Borrowed HTTP Gun correlation can supply the base view; invalid wire correlation stays local.],
      [Absent discovered structuredContent is None, including continuation rounds; explicit null is Some(Null). output.require_discovered projects text only on actual absence and does not inspect outputSchema to invent presence. See #adr(5).],
    )
    #behavior(title: "Invalid idempotency key fails before sending", area: "Client controls", level: "interface")[
      #given[A client view has an empty, oversized or non-visible-ASCII idempotency key.]
      #when[It attempts a request.]
      #then[The result is InvalidArguments with NotSent evidence and the call's correlation.]
    ]
    #behavior(title: "Preserve present structured null", area: "Discovered output", level: "interface")[
      #given[A discovered call completes with structuredContent explicitly null and nonempty text.]
      #when[The caller requires the discovered output.]
      #then[The answer remains Null rather than the content's text.]
    ]
  ])

  #section(title: "Bearer admission and tool policy", lead: "A trusted verifier supplies claims; Relay admits resource authority and applies current request policy.", body: [
    #points([The configured verifier's #term("term-attestation") is admitted against #term("term-protection") to produce a #term("term-grant"). The caller translates that grant into #term("term-context"); it does not replace endpoint admission with a web-login identity.])
    #answers(title: "Resource-server authorization", responsibility: [Parse bearer headers, admit exact resource/scopes, render challenges and metadata.], interface: [BearerToken/ProtectedResource/Scope constructors; verifier(name, fn(token,correlation)); attestation; admit; Grant readers; Protection; challenge and resource_metadata.], interactions: [new_protected calls the selected verifier and builds native context from Grant; Warden may supply an independently configured verifier recipe but Relay does not import it.], invariants: [Singleton exact resource audience; all endpoint scopes present; retain actual scopes; correlation never affects admission; token not retained as Grant field.], failure: [MissingToken, VerificationFailed, ResourceNotGranted and MissingEndpointScope produce distinct internal decisions; public HTTP status/challenge is sanitized.])
    #md-table(3, (
      [*Refusal*], [*Response*], [*Caller action*],
      [Missing token], [401 Bearer with resource_metadata; no error code], [Discover protected-resource metadata or supply credentials.],
      [Rejected/unmapped/wrong-resource token], [401 invalid_token], [Refresh or reauthorize under resource/issuer policy; no infinite 401 loop.],
      [Missing required scope], [403 insufficient_scope and required scopes], [Explicit step-up policy.],
      [Verifier unavailable], [503 without authentication challenge], [Verifier availability is not invalid identity.],
      [Hidden/denied/unknown tool], [One inaccessible protocol outcome], [No tool-existence disclosure; handler and decoder untouched.],
    ))
    #points(
      [The verifier owns signature, issuer, expiry, status, algorithm, key rotation, introspection and sender-constraint checks. Its Attestation constructor can assert arbitrary claims; the application selects and trusts that implementation. Empty audience/scope strings are filtered before exact admission; duplicate/additional audiences still fail the singleton profile.],
      [Protection stores an absolute HTTP(S) resource URI without fragment, nonempty exact scopes and declared authorization servers. URI and scope equality are exact configured strings; no path, case, alias or audience-set normalization grants authority.],
      [BearerToken captures raw value inside a closure to reduce accidental inspect disclosure; token_value intentionally reveals it to the verifier. A caller-owned principal can still retain secrets, so token redaction remains an adapter and observation obligation.],
      [new_protected runs admission on each HTTP request before building context. The historical protected-registry wrapper is superseded; grants are translated into native context and server.with_tool_access filters listings and rechecks visible+callable before argument decode. Per-input permissions remain in typed handlers.],
      [The metadata GET at `/.well-known/oauth-protected-resource` plus resource path reports resource, authorization servers, scopes and header bearer method. Challenge header escaping and status behavior belong to Relay; token validity remains outside it.],
      [A Warden web identity cannot substitute for a Relay grant. Relating a login identity to bearer principal, tenant and business access is explicit application policy. Multiple trust domains sharing resource and principal type need explicit verifier-origin reuse rules. See #adr(4).],
    )
    #behavior(title: "Additional audience prevents admission", area: "Resource grants", level: "interface")[
      #given[A trusted verifier returns a valid token attestation with the configured audience and one additional audience.]
      #when[Relay admits it under the singleton resource profile.]
      #then[It returns ResourceNotGranted and no Grant or tool work is admitted.]
    ]
    #behavior(title: "Unavailable verification is not invalid authentication", area: "Authorization failure", level: "interface")[
      #given[The configured verifier cannot obtain enough evidence to decide token validity.]
      #when[It returns VerifierUnavailable.]
      #then[The protected server answers 503 without WWW-Authenticate and emits the unavailable decision.]
    ]
  ])

  #section(title: "Composition ports and observations", lead: "Applications translate protocol evidence and native execution outcomes at small explicit boundaries.", body: [
    #points([The application maps #term("term-evidence") into its effect model. #term("term-correlation") joins observations, while #term("term-idempotency-key") acquires business meaning only under authenticated principal and application policy.])
    #contract(name: "Typed tool output port", mission: "Expose answer, failure classification, evidence and reply metadata without importing an agent runtime.", answers: answers-data(
      responsibility: [Return native output or structured projection failures.], interface: [relay/client/output require, require_discovered, error_kind, evidence, describe_error, meta; tool.complete_with_meta; content.text_of.],
      interactions: [An application translates its durable-run or agent vocabulary; full ToolResult remains available for media and interaction.], invariants: [CallFailed retains original Error; ToolFailed and InputRequired retain Completed evidence; metadata lookup imposes no Fabric key.], failure: [Projection loss is explicit; uncertain transport does not become application refusal.],
    ))
    #points(
      [Fabric invoke owns principal+key run identity, matching-input reopen, wait, cancellation and durable outcome. A Relay recipe copies request correlation/key, builds invoke request from native principal/input, sets its wait shorter than Relay's invocation budget, and returns native result plus application run metadata.],
      [For an unkeyed request the recipe forwards tool.cancelled to the owned invoke wait; keyed work may retain its durable run under application policy. Relay's JSON-RPC id and InvocationId never identify that durable run.],
      [Discovery has separate listing and schema/name admission boundaries. The application decides peer trust before treating readOnlyHint as evidence that MaybeSent work is safe to repeat. tool_hub trusts the inventory endpoint it owns; this is not a general trust policy for arbitrary remote peers.],
      [Secure MCP uses a Warden resource-verifier recipe and native principal context. Warden validates token cryptography/introspection with its own limits; Relay maps resource/scope admission and challenges. Independent Warden bounds do not repair Relay's callback budget gap.],
    )
    #answers(title: "Correlation and telemetry", responsibility: [Carry request observation identity and emit typed protocol facts after transitions.], interface: [client.with_correlation, http.with_correlation, tool.correlation, telemetry event descriptors; Sinal observers.], interactions: [HTTP x-correlation-id and `_meta` io.github.gleam-dream/correlation join client, endpoint, verifier, handler and downstream events.], invariants: [Every request gets a Correlation; precedence is transport override, valid carried value, then fresh; accepted wire value is 1–128 visible ASCII; correlation never authorizes.], failure: [Invalid carried correlation is ignored rather than refusing the call; before-call errors carry a fresh local-only correlation; rejected frame has no admitted request correlation.])
    #md-table(2, (
      [*Event*], [*Transition observed*],
      [frame.rejected / http.rejected], [Boundary refusal before admitted work],
      [request.admitted], [Accepted protocol request],
      [invocation.started / completed / cancelled / crashed], [Worker execution, result, cancellation intent or crash/timeout; duration on completion],
      [exchange.closed], [Terminal destination with its request correlation],
      [authorization.decided], [Configured verifier/resource admission decision],
      [client.call], [Call outcome and elapsed duration with outgoing correlation],
    ))
    #points([Observation callbacks do not choose protocol results. Request ids, correlation and idempotency keys are untrusted independent values; the authenticated principal controls business authority. The optional idempotency metadata key is io.github.gleam-dream/idempotency-key, accepted only for 1–128 visible ASCII. See #adr(5).])
  ])

  #section(title: "Validation and extension ownership", lead: "Structural validity, runtime fidelity and complete conformance require different evidence.", body: [
    #answers(title: "Public testing and evidence tools", responsibility: [Provide deterministic local serving/calling and validate compiler, schema, runtime and external contracts independently.], interface: [testing.connect/error/request/body_text/verifier/unavailable_verifier; test suites and peer fixtures; schema/negative/checksum scripts; pinned conformance runner.], interactions: [In-process uses the same wire and runtime; fixture peers exercise hostile declarations/continuations/subscriptions; conformance launches a local endpoint; external recipes compile in Fabric consumers and application checkouts.], invariants: [Schema checksum and sibling revisions recorded; tests use actual encoder bytes; unsupported features and suite omissions remain explicit; no selected scenario or expected-failure file claims full conformance.], failure: [Wrong native handler codec fails compilation; schema mutations fail validation; runtime races need process/socket assertions; client and auth suites require independent invocation.])
    #md-table(3, (
      [*Evidence layer*], [*What it proves*], [*What it cannot prove*],
      [Compiler / negative fixture], [Native codec/handler agreement and public construction boundaries], [Runtime lifecycle or token authenticity],
      [Frozen JSON schema corpus], [Actual wire output shape and required-field mutations], [Behavior, framing or complete protocol conformance],
      [Pure/property/race histories], [One authoritative transition history, ids, terminal suppression], [Exclusive interpreter ownership or stopped external effects],
      [Runtime / real HTTP / child tests], [Measured process cleanup, acknowledged backpressure, disconnect and FIFO behavior], [All OS/library versions or untested admission/allocation bounds],
      [Pinned server conformance], [Emitted assertions for frozen 2026-07-28 server scenarios], [Client/auth/legacy support or zero-check scenario coverage],
      [External consumers], [Common and advanced public usage with caller-native types and failure handling], [General third-party schema/peer trust or production provider acceptance],
    ))
    #points(
      [test/fixtures/mcp_2026 retains upstream raw bytes, checksum, commit and MIT license. scripts/conformance retains package and lockfile; acceptance uses the pinned 0.2.0-alpha.10 requirement anchor. See #adr(7).],
      [Keep split UTF-8/large frames, broken stdout with idle stdin, owner/child death, equal wire ids, duplicate admission, cancellation races, tombstones, held-writer mailbox bounds, burst disconnect, registry-generation barriers, FIFO subscription timeout and overflow fixtures. Source assertion names supply reproduction points, not a test-run diary.],
      [Revision codecs, custom template matcher, generic verifier and reducer interpreter are extension contracts with different ownership. A new transport must prove framing, limits, disconnect/cancellation and cleanup from an external consumer; a buffering interface cannot fabricate socket ownership.],
      [A new protocol revision carries its schema, requirements, supported-method set and independent lifecycle strategy. Supported-version removal requires a major version; deprecation lasts at least a minor release. Older than 2025-03-26 is excluded.],
      [Release verification retains Erlang/OTP target matrices, pinned TypeScript/Python peers in both directions, Inspector smoke, fuzz/soak/cancellation storms, bounded process/mailbox evidence and continuous latest-harness/schema drift. No completed hardening run is inferred from the standing design.],
    )
  ])

  #section(title: "Retained protocol strategies", lead: "Full scope includes separately modeled compatibility and authorization flows.", body: [
    #answers(title: "Legacy compatibility strategy", responsibility: [Admit a session through initialize, negotiate revision/capabilities and gate requests on initialized readiness.], interface: [Intended revision-bound client/server codecs and session owner; no legacy public runtime is implemented.], interactions: [Share native definitions, results and application ports; keep session registry, idle/max-session limits, transport resumption and revision notifications separate from modern POST-only execution.], invariants: [Reject repeated initialize, stale/unknown session, early normal calls and post-initialization version disagreement; resultType remains absent.], failure: [Revision-specific protocol failures, cleanup, unsupported capability and session termination outcomes; initialize cancellation rules must match the frozen revision.])
    #state-type(id: "legacy-phase", title: "Legacy session phase", variants: ("AwaitingInitialize", "AwaitingInitialized", "Ready", "Closed"))
    #entity(id: "legacy-session", title: "Legacy session", description: [Retained design for negotiated 2025-11-25 lifecycle, absent from modern state.], kind: "aggregate", owner: "legacy session runtime", lifecycle: "stateful", domain: "MCP", tint: "blue")[
      #attribute(id: "phase", name: "Phase", type: [Legacy session phase], provenance: "derived", state-type: "legacy-phase", state-machine: "legacy-life")[Only valid initialize establishes negotiated version, capabilities and session identity.]
      #relates(cardinality: "1 : 0..n")[One ready legacy session may own requests and its notification/resumption stream.]
    ]
    #state-machine(id: "legacy-life", subject: "legacy-session", state-field: "phase", state-type: "legacy-phase", title: "Retained legacy handshake", initial: "AwaitingInitialize", accepting: ("Closed",), states: ("AwaitingInitialize", "AwaitingInitialized", "Ready", "Closed"), transitions: (
      ("AwaitingInitialize", "AwaitingInitialized", "valid initialize selects revision"), ("AwaitingInitialized", "Ready", "initialized notification"),
      ("Ready", "Closed", "DELETE / idle / owner shutdown"), ("AwaitingInitialized", "Closed", "initialization lifetime ends"),
    ), caption: [No transition from modern discovery creates this session. Early or repeated handshake messages reject without changing the phase.])
    #answers(title: "MCP client authorization strategy", responsibility: [Own MCP-specific resource discovery, issuer-bound credentials, scope step-up and bounded reauthorization.], interface: [Intended static bearer, authorization-code PKCE, client credentials and private-key-JWT modes; preregistration, permitted dynamic registration and client metadata documents; pluggable memory/file token custody.], interactions: [Challenge → RFC 9728 resource metadata → RFC 8414 or permitted OIDC metadata → registration → authorization/token exchange; application callback handles user interaction.], invariants: [Bind state, PKCE verifier, selected issuer, callback issuer, resource, redirect and scopes; reject replay/forged state; persist rotation before using refresh credentials; coalesce concurrent 401 flows.], failure: [Discovery/issuer/registration/token/PKCE/callback/step-up failures remain explicit; repeated 401 retry is bounded; malicious discovery cannot relax credential or network policy.])
    #points(
      [Legacy 2025-03-26 and 2025-06-18 remain deferred supported-target ambitions. Deprecated dual-endpoint HTTP+SSE is optional compatibility; GET notification streams, Last-Event-ID, reconnect hints, ordered event replay and duplicate suppression require separate revision evidence. Parser carry-over alone does not prove exactly-once delivery.],
      [Logging retains an approved typed request-scoped emitter and legacy set-level behavior where defined. Arbitrary handler JSON logging was rejected in prior automatic review and remains absent; no indirect sender may be treated as approved.],
      [Retained resource-read continuation, rich client interactions, form/URL elicitation outcomes, roots, sampling and extension methods are capability checked and revision scoped. Deprecated server-initiated behavior is not transplanted into modern wire methods.],
      [Tasks, Apps, DPoP, mTLS sender constraints, replay checks and workload identity require explicit pinned models and consumers. Public helpers retain paired transports, fake clock, scripted peers and configurable authorization metadata/JWKS server as unbuilt support.],
      [The retained eight-distribution and dual-target ambitions change no capability responsibility: one package remains the implemented distribution; independent package/target splits require consumer and dependency evidence. See #adr(1) and #adr(7).],
    )
  ])

  #section(title: "End-to-end walkthrough", lead: "A protected typed operation keeps protocol evidence separate from the business effect.", body: [
    #points(
      [An application owns Item and LookupError records and their input/output codecs. It defines lookup once, binds a handler with an explicit safe error renderer, creates server.new, and supplies its own principal/context policy.],
      [The protected HTTP endpoint validates its configuration before acquiring a listener. Its configured verifier checks the presented token and returns principal, audience and scopes; Relay admits exactly its resource and required scopes, then constructs native context in the serving request process.],
      [A client connects to the endpoint using one configuration and a view with a 10-second absolute deadline, cancellation token, correlation and optional order key. The request carries modern metadata and agreeing routing headers; schema and tool access refusal occur before the handler.],
      [The endpoint allocates an exchange, the runtime admits one invocation and the handler receives Call with native context, correlation and cancellation. It performs lookup or explicitly maps a durable invoke port, whose wait must fit inside the transport budget.],
      [A successful structured answer has native output plus content mirror; a safe application failure becomes ToolFailed; a required input round returns an originating continuation. On lost delivery the client receives MaybeSent and must consult business identity/reconciliation before retrying a mutation.],
      [A streaming peer disconnect closes publication and signals cancellation; the worker gets grace to stop work it owns elsewhere. Client close releases Relay-owned resources; endpoint stop disconnects its listener failure link before intentional termination. Shared HTTP Gun and business receipts retain their own application owners.],
      [The boundary gap is visible even in this path: verifier/context time is outside Relay's current invocation budget. A caller needing an end-to-end bound must bound those callbacks independently until the admission model is decided. No evidence above proves that an external business effect was undone.],
    )
  ])
]
