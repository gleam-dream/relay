# relay

Relay implements the frozen MCP `2026-07-28` revision in Gleam. Its public surface has a pure server reducer, typed tools and services, bounded stdio and Streamable HTTP transports, a typed client, and optional authorization primitives.

## Native tools

```gleam
import json/blueprint/codec
import relay/server
import relay/tool
import relay/transport/stdio

pub fn main() {
  let assert Ok(name) = tool.tool_name("greet")
  let assert Ok(definition) =
    tool.definition(name, codec.field("name", codec.string()), codec.string())
  let definition =
    definition |> tool.with_description("Greets the user by name")
  let bound = tool.handle(definition, fn(name) { Ok("Hello, " <> name <> "!") })
  let assert Ok(registry) = tool.registry([bound])
  let service = server.server(registry)
  let _ = stdio.run_local_unprotected_stdio_server(
    service,
    stdio.default_stdio_config(),
    Nil,
  )
}
```

The same `Definition(input, output)` supplies `client.call_definition` and the input/output codecs used by an application-owned LLM adapter. Remote JSON Schema documents do not reconstruct native types, and provider tool names need their own admission checks. A caller-supplied object schema can be attached with `tool.with_input_schema_override`; the input codec still validates every call.

`tool.handle` exposes the generic message `Tool execution failed.` for application errors. `tool.handle_with_error_renderer` deliberately publishes a caller-rendered message. A renderer may return JSON text, for example `codec.encode_json(error_codec, error)`, when a peer needs an encoded error shape; no error codec is required for registration. `tool.handle_advanced` and its renderer variant receive `HandlerCallContext`, which carries per-invocation application context, client input responses, and a progress callback. `HandlerResult` distinguishes structured output with content, content-only output, and another input round.

A content-only tool uses `tool.content_definition(name, input_codec)` and `tool.handle_content`. It has no output codec or structured result promise. `client.call_content_definition` returns `Result(List(ContentBlock), ContentCallError)`. `tool.content_with_input_schema_override` admits a caller-supplied discovery schema while the input codec still validates calls. An advanced handler uses `tool.handle_content_advanced` and returns `ContentComplete(blocks)` or `ContentNeedsInput(requests)`; it receives application context, progress, and prior input responses. Metadata is a caller-owned `ToolMetadata` value; `tool.content_with_metadata` attaches it to the admitted content definition. Annotation hints compose independently with `tool.empty_annotations` and the hint modifiers. `None` omits a hint; `Some(False)` publishes false.

## Services and transports

`server.server(registry)` creates an immutable description. `server.with_resources`, `server.with_resource_templates`, and `server.with_prompts` replace their respective lists; `server.with_completion` sets or clears completion. Each modifier preserves the registry, custom dispatch, and unrelated services. `server.with_dispatch` receives the current registry at every invocation, including after dynamic registration. Simple resource, prompt, and completion handlers may return application-owned errors; their details are hidden by the existing wire failure mapping.

`resources.resource_template` admits a URI template before it can be advertised. The built-in matcher accepts one simple `{name}` variable per slash segment, including embedded forms such as `urn:record:{id}.png`, and rejects unsupported operators or composite variables. `resources.resource_template_with_matcher` accepts a caller-owned matcher for other syntax after validating the URI scheme. Value-first template modifiers retain title, description, MIME type, and annotations.

The public reducer (`server.step`) and runtime support custom transports. `runtime.start` validates its `RuntimeConfig` before creating an actor and sends `OutputWrite(exchange, bytes)` and `OutputClose(exchange)` to the transport sink. A failed write closes only its exchange; `runtime.exchange_closed` lets the transport report a peer disconnect without stopping unrelated invocations. `runtime.close` still closes the full connection. Stdio validates its chunk size and runtime settings before touching standard I/O.

`http.listener(service, fn() { context })` starts with a local ephemeral bind and local Host/Origin policy. Apply `http.with_options`, `http.with_policy`, and optionally `http.with_tls`, then call `http.start`. `HttpPolicy.sse_keepalive_ms` is a positive caller-controlled SSE keepalive interval; the default remains 250 ms. Changing bind options does not widen the policy or add authentication. Startup checks bounds, bind interface, and readable TLS files before allocating the runtime hub.

`client.http_config("https://localhost:8443/")` derives host, port, path, and TLS from an absolute HTTP(S) URL. It rejects userinfo, query, fragment, malformed authority/path, and invalid ports; a missing path becomes `/`. `client.with_timeout`, `client.with_max_response_bytes`, and `client.with_ca_cert_file` change explicit settings before `client.connect_http`; a CA setting on plain HTTP is rejected. For a local child process, `client.stdio_config(executable, args)` supplies bounded timeout and response defaults, with named record updates available for different limits before `client.connect_stdio`.

`client.list_tools` returns remote declarations with their JSON Schema documents intact. `client.call_discovered(peer, declaration, arguments)` accepts exact Blueprint `Value` arguments and returns exact `Value` structured output together with rich content blocks; `ToolFailure`, `ProtocolFailure`, and `TransportFailure` remain separate. A caller can parse provider-authored argument JSON with Blueprint's public parser and forward the result without a native input codec or numeric rounding. The native `call_definition` path keeps its output codec. `call_content_definition` returns `ContentCallOutcome` without a dummy structured type. `raw_json_call` remains for methods the typed client does not cover.

Input rounds are explicit. HTTP `client.with_input_methods(config, [client.Elicitation])` and the corresponding `StdioConfig.input_methods` field advertise supported methods per request; both default to `[]`. An `InputRequired(continuation, requests)` result retains the client, tool name, original arguments, and opaque request state. The application handles each request and calls `client.resume_tool(continuation, responses)` with exactly one JSON result object per request key. For `elicitation/create`, an accepted form response is `json.object([#("action", json.string("accept")), #("content", json.object([...]))])`; `sampling/createMessage` expects a CreateMessageResult object and `roots/list` a ListRootsResult object. These are the frozen protocol result bodies, without a JSON-RPC envelope. An empty request map can still carry request state and be resumed with an empty response map. The client does not run an automatic responder.

`client.default_listing_limits()` bounds aggregate listings to 256 pages and 10,000 items. Use `client.with_listing_limits(config, client.ListingLimits(max_pages, max_items))` for HTTP or the `StdioConfig.listing_limits` field for stdio. Nonpositive limits fail before opening a transport. Tool-call transport failures distinguish `ConnectionClosed`, `RequestCancelled`, `RequestTimedOut`, `ResponseLimitExceeded`, and other `TransportFault(message)` values without inspecting diagnostic strings.

The server handles discovery, typed tool calls, rich text/image/audio/resource content, resources/templates, prompts, completion, progress, multi-round tool and prompt input, subscriptions, and bounded request-scoped SSE. The client offers typed listings, paginated checked JSON listings, typed resource/prompt/completion operations, raw checked JSON-RPC calls, and live subscriptions. The stdio transport serializes stdout and isolates diagnostics on stderr. Sinal events cover admission, rejection, invocation lifecycle, and exchange closure.

The currently available stdio and HTTP listeners are unprotected. The authorization module provides verifier, grant, policy, and protected-registry primitives, but those listeners do not yet enforce bearer grants. Bind them to trusted local environments. Relay does not claim complete MCP conformance or production readiness. Legacy `2025-11-25` support, `logging/setLevel`, and resource-read continuation remain outside this implementation.

The pinned `@modelcontextprotocol/conformance@0.2.0-alpha.10` Streamable HTTP server suite previously reported 109 passed checks and 0 failures across 40 requirement scenarios. One scenario emits no checks for this revision, so this result does not establish complete conformance.

## Verification

```bash
nix develop --command gleam format --check src test
nix develop --command gleam check
nix develop --command gleam build
nix develop --command gleam build --warnings-as-errors
nix develop --command gleam test
nix develop --command python3 scripts/check_negative_fixtures.py
nix develop --command python3 scripts/relay_schema_check.py
nix develop --command ./scripts/verify_checksums.sh
./scripts/conformance/run-server-suite.sh
nix flake check
```
