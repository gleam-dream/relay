# Wave 4 migration

Wave 4 redesigns Relay's public API for its first release (RELAY-R1 to R16).
Every module changed. This guide lists each removed or changed public item
with its replacement, grouped by module, and ends with the symbols each
dependent uses.

The main changes:

- **Durations.** Every timeout, interval and grace period is a
  `gleam/time/duration.Duration`. No setter takes milliseconds or ends in
  `_ms`. A dependent that names `Duration` adds
  `gleam_time = ">= 1.11.0 and < 2.0.0"`.
- **Total definitions.** `tool.define`, `server.new` and
  `resources.template` panic with the offending name on a definition
  mistake, because definitions are written in source code. `try_define`,
  `try_template` and `server.register_tool` return typed errors for
  definitions built at runtime (decision 4).
- **Opaque configuration.** `HttpOptions`, `HttpPolicy`, `RuntimeConfig`,
  `StdioConfig`, `LocalUnprotectedStdioConfig`, `ListingLimits`,
  `ToolMetadata` and `ToolAnnotations` builders became opaque values with
  `with_*` setters (convention 1).
- **A mountable HTTP endpoint.** `relay/http` builds a handler you mount in
  wisp or mist, with a context built from the request, bearer protection,
  supervision and bounded defaults.
- **One client error.** Every client operation returns
  `Result(_, client.Error)`; the error carries the HTTP status, the JSON-RPC
  error or the transport failure with its `Evidence`. The client runs on
  HTTP Gun.
- **Spec-exact protocol data.** Content blocks, annotations, icons and
  declarations mirror the frozen `2026-07-28` schema, `_meta` included;
  binary data is bytes.

Defaults that changed: SSE keepalive 250 ms → 15 s; concurrent HTTP requests
unbounded → 1,024 then 503; concurrent `subscriptions/listen` streams
unbounded → 64 then 503; JSON nesting depth unbounded → 64; runtime
tombstones unbounded in count → 10,000; stdio client pending calls unbounded
→ 64; client connect wait 30 s → 10 s; a cancelled handler is signalled and
killed after a 5 s grace instead of killed at once.

Contents: [modules](#module-moves) · [tool](#relaytool) ·
[content](#relaycontent) · [resources](#relayresources) ·
[prompts](#relayprompts) · [completion](#relaycompletion) ·
[subscriptions](#relaysubscriptions) · [server](#relayserver) ·
[reducer](#relayreducer) · [runtime](#relayruntime) ·
[telemetry](#relaytelemetry) · [authorization](#relayauthorization) ·
[http](#relayhttp) · [stdio](#relaystdio) · [client](#relayclient) ·
[testing](#relaytesting) · [dependents](#dependents)

## Module moves

| Before                                   | After                                                                                   |
| ---------------------------------------- | --------------------------------------------------------------------------------------- |
| `relay/transport/http`                   | `relay/http`                                                                            |
| `relay/transport/stdio`                  | `relay/stdio`                                                                           |
| `relay/server` (description and reducer) | `relay/server` (description), `relay/reducer` (pure reducer)                            |
| `relay/protocol/jsonrpc`                 | internal (`RequestId`, `RpcError` no longer public; `client.RpcError` carries the code) |
| `relay/protocol/revision`                | removed (Relay implements `2026-07-28` only)                                            |
| `relay/logging`                          | internal                                                                                |
| `relay/subscriptions.SubscriptionFilter` | `relay/subscriptions.Notification`                                                      |
| `relay_conformance_server`               | `dev/relay_conformance_server.gleam` (not published)                                    |
| —                                        | `relay/testing` (new)                                                                   |

## `relay/tool`

| Before                                                                                                                                                                                                                                                                                           | After                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ToolName`, `tool_name(raw)`, `tool_name_to_string`, `ToolNameError`                                                                                                                                                                                                                             | names are `String`; `define` validates them                                                                                                                                                                                           |
| `definition(name, input, output) -> Result(Definition, ToolAdmissionError)`                                                                                                                                                                                                                      | `define(name, input, output) -> Definition` (panics); `try_define(..) -> Result(Definition, DefineError)`                                                                                                                             |
| `content_definition(name, input) -> Result(ContentDefinition, _)`                                                                                                                                                                                                                                | `define_content(name, input) -> Definition(input, List(ContentBlock))`; `try_define_content`                                                                                                                                          |
| `ContentDefinition(input)`                                                                                                                                                                                                                                                                       | `Definition(input, List(ContentBlock))`                                                                                                                                                                                               |
| `ToolAdmissionError`                                                                                                                                                                                                                                                                             | `DefineError`: `EmptyName`, `NameTooLong`, `InvalidNameCharacter`, `MissingInputSchema`, `InputSchemaNotObject`, `MissingOutputSchema`, `OutputSchemaNotObject`; `describe_define_error`                                              |
| `ToolMetadata`, `empty_metadata`, `with_metadata`, `content_with_metadata`, `definition_metadata`                                                                                                                                                                                                | setters on `Definition`; read with `declaration(d)`                                                                                                                                                                                   |
| `ToolAnnotations` builder: `empty_annotations`, `with_read_only_hint(a, Option(Bool))`, … , `with_annotations`, `tool_annotations_to_json`                                                                                                                                                       | `with_read_only_hint(d, Bool)`, `with_destructive_hint`, `with_idempotent_hint`, `with_open_world_hint` on the definition; `ToolAnnotations` stays as a read record                                                                   |
| `with_required_client_capabilities`                                                                                                                                                                                                                                                              | unchanged name, on `Definition`                                                                                                                                                                                                       |
| `with_input_schema_override(d, Value) -> Result(..)`, `content_with_input_schema_override`                                                                                                                                                                                                       | `with_input_schema(d, Value) -> Definition` (panics on a non-object)                                                                                                                                                                  |
| —                                                                                                                                                                                                                                                                                                | `with_title`, `with_icons(List(content.Icon))`, `with_meta(content.Meta)`                                                                                                                                                             |
| `definition_name(d) -> ToolName`, `content_definition_name`                                                                                                                                                                                                                                      | `name(d) -> String`                                                                                                                                                                                                                   |
| `definition_input_codec`, `content_definition_input_codec`                                                                                                                                                                                                                                       | `input_codec(d)`                                                                                                                                                                                                                      |
| `definition_output_codec(d) -> Codec(o)`                                                                                                                                                                                                                                                         | `output_codec(d) -> Option(Codec(o))` (`None` for a content tool)                                                                                                                                                                     |
| `ToolDeclaration(name: ToolName, metadata, input_schema: Schema, input_schema_override, output_schema: Option(Schema))`, `client.ToolDeclaration`                                                                                                                                                | one `Declaration(name, title, description, input_schema: Value, output_schema: Option(Value), annotations: ToolAnnotations, icons, meta)`; `declaration(d)`, `tool_declaration(t)`, `input_contract(declaration)`                     |
| `ContextTool(context)`                                                                                                                                                                                                                                                                           | `Tool(context)`                                                                                                                                                                                                                       |
| `tool_name_of(t)`, `tool_declaration_of(t)`                                                                                                                                                                                                                                                      | `tool_declaration(t).name`, `tool_declaration(t)`                                                                                                                                                                                     |
| `handle(d, fn(i) -> Result(o, e))`                                                                                                                                                                                                                                                               | unchanged                                                                                                                                                                                                                             |
| `handle_with_error_renderer(d, handler, fn(e) -> String)`                                                                                                                                                                                                                                        | `handle_with_error_renderer(d, handler, fn(e) -> ToolError)`; build with `error_message(text)` or `error_with(blocks, structured)`                                                                                                    |
| `handle_advanced`, `handle_advanced_with_error_renderer`, `handle_content`, `handle_content_with_error_renderer`, `handle_content_advanced`, `handle_content_advanced_with_error_renderer`                                                                                                       | `handle`, `handle_with_error_renderer`, or `handle_call(d, fn(Call(ctx), i) -> Result(Reply(o), ToolError))`                                                                                                                          |
| `HandlerCallContext(application, input_responses, report_progress)`                                                                                                                                                                                                                              | opaque `Call(ctx)`: `context(call)`, `input_responses(call) -> Dict(String, Value)`, `report_progress(call, Float, Option(Float), Option(String))`, `cancelled(call) -> Selector(Nil)`, `invocation_id`, `correlation`, `client_info` |
| `ProgressReporter = fn(Int) -> Nil`                                                                                                                                                                                                                                                              | `report_progress(call, progress, total, message)`                                                                                                                                                                                     |
| `HandlerResult`: `Complete(o, blocks)`, `Content(blocks)`, `NeedsInput(requests)`; `ContentHandlerResult`                                                                                                                                                                                        | opaque `Reply(o)`: `complete(o)`, `complete_with_content(o, blocks)`, `request_input(requests)`                                                                                                                                       |
| `InputRequest(method: String, params: json.Json)`                                                                                                                                                                                                                                                | `InputRequest(method: InputMethod, params: Value)`; `InputMethod` (`Elicitation`, `Sampling`, `Roots`) moved from `relay/client`; `input_method_name`                                                                                 |
| `ToolOutput`, `DispatchError`, `Registry`, `registry`, `register`, `unregister`, `contains`, `registered_tools`, `declarations`, `required_client_capabilities`, `input_schema_document`, `dispatch`, `dispatch_with_content`, `dispatch_with_progress`, `dispatch_with_inputs`, `RegistryError` | removed: `relay/server.new` owns the tool list; `server.register_tool` returns `DuplicateTool`                                                                                                                                        |

```gleam
// Before
let assert Ok(name) = tool.tool_name("search")
let assert Ok(search) = tool.definition(name, query_codec(), result_codec())
let search =
  search
  |> tool.with_description("Find products.")
  |> tool.with_annotations(
    tool.empty_annotations() |> tool.with_read_only_hint(Some(True)),
  )
let bound =
  tool.handle_with_error_renderer(search, run, fn(error) { describe(error) })

// After
let search =
  tool.define("search", query_codec(), result_codec())
  |> tool.with_description("Find products.")
  |> tool.with_read_only_hint(True)
let bound =
  tool.handle_with_error_renderer(search, run, fn(error) {
    tool.error_message(describe(error))
  })
```

```gleam
// Before: an advanced handler
tool.handle_advanced(definition, fn(call, input) {
  let tool.HandlerCallContext(context, responses, report) = call
  report(50)
  case responses {
    None -> Ok(tool.NeedsInput(requests))
    Some(_) -> Ok(tool.Complete(output(context, input), []))
  }
})

// After
tool.handle_call(definition, fn(call, input) {
  tool.report_progress(call, 50.0, Some(100.0), None)
  case dict.is_empty(tool.input_responses(call)) {
    True -> Ok(tool.request_input(requests))
    False -> Ok(tool.complete(output(tool.context(call), input)))
  }
})
```

```gleam
// Before: deriving another tool from a definition
let metadata = tool.definition_metadata(definition)
let name = tool.definition_name(definition) |> tool.tool_name_to_string
let output = tool.definition_output_codec(definition)
case metadata.annotations {
  Some(tool.ToolAnnotations(read_only_hint: Some(True), ..)) -> ReadOnly
  _ -> Effectful
}

// After
let declaration = tool.declaration(definition)
let name = tool.name(definition)
let assert Some(output) = tool.output_codec(definition)
case declaration.annotations.read_only_hint {
  Some(True) -> ReadOnly
  _ -> Effectful
}
```

A handler that waits on other work can stop when the call is cancelled:

```gleam
tool.handle_call(definition, fn(call, job) {
  let run = start(job)
  case process.selector_receive(tool.cancelled(call) |> await(run), 60_000) {
    Ok(Done(output)) -> Ok(tool.complete(output))
    _ -> {
      stop(run)
      Error(tool.error_message("cancelled"))
    }
  }
})
```

## `relay/content`

| Before                                                                                                                                                                  | After                                                                                                                                                                    |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Annotations(audience: Option(List(Role)), priority, title, description)`                                                                                               | `Annotations(audience: List(Role), priority: Option(Float), last_modified: Option(String))` (the 2026-07-28 shape)                                                       |
| `TextContent(text, annotations)`                                                                                                                                        | `TextContent(text, annotations, meta)`                                                                                                                                   |
| `ImageContent(data: String, mime_type, annotations)`                                                                                                                    | `ImageContent(data: BitArray, mime_type, annotations, meta)`: raw bytes, base64 only on the wire                                                                         |
| `AudioContent(data: String, ..)`                                                                                                                                        | `AudioContent(data: BitArray, mime_type, annotations, meta)`                                                                                                             |
| `EmbeddedResourceBlock(EmbeddedResource(resource, annotations))`, `EmbeddedResource`                                                                                    | `EmbeddedResourceBlock(resource, annotations, meta)`                                                                                                                     |
| `ResourceLink(uri, name, title, description, mime_type, size, annotations)`                                                                                             | adds `icons: List(Icon)` and `meta`                                                                                                                                      |
| `TextResourceContents(uri, text, mime_type)`                                                                                                                            | `TextResourceContents(uri, text, mime_type, meta)`                                                                                                                       |
| `BlobResourceContents(uri, blob: String, mime_type)`                                                                                                                    | `BlobResourceContents(uri, blob: BitArray, mime_type, meta)`                                                                                                             |
| `text_content(text)`, `image_content(data, mime)`, `audio_content(data, mime)`                                                                                          | `text(text)`, `image(bytes, mime)`, `audio(bytes, mime)`; also `resource_link(uri, name)`, `embedded(resource)`, `text_resource(uri, text)`, `blob_resource(uri, bytes)` |
| `client.Icon`, `client.IconTheme` (`IconLight`, `IconDark`)                                                                                                             | `content.Icon(src, mime_type, sizes: List(String), theme)`, `content.IconTheme` (`LightTheme`, `DarkTheme`), `icon(src)`                                                 |
| `role_to_string`, `role_from_string`, `annotations_to_json`, `resource_contents_to_json`, `resource_link_to_json`, `embedded_resource_to_json`, `content_block_to_json` | internal                                                                                                                                                                 |
| —                                                                                                                                                                       | `Meta = List(#(String, Value))`, `with_annotations(block, a)`, `with_meta(block, meta)`                                                                                  |

```gleam
// Before
content.ImageContent(png_base64, "image/png", None)
content.TextResourceContents(uri, text, Some("text/plain"))

// After
content.image(png_bytes, "image/png")
content.TextResourceContents(uri, text, Some("text/plain"), [])
```

## `relay/resources`

| Before                                                                                                                                                                        | After                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `resource(uri, name, read) -> ContextResource(ctx)`                                                                                                                           | `static(uri, name, read) -> Resource(ctx)`                                                                                                     |
| `resource_template(t, name, read) -> Result(ContextResourceTemplate, TemplateError)`                                                                                          | `template(t, name, read) -> Resource(ctx)` (panics); `try_template(..) -> Result(Resource, TemplateError)`                                     |
| `resource_template_with_matcher(t, name, read, matches) -> Result(..)`                                                                                                        | `template_with_matcher(t, name, read, matches) -> Resource(ctx)`                                                                               |
| `ContextResource` (public record), `ContextResourceTemplate`                                                                                                                  | one opaque `Resource(ctx)`                                                                                                                     |
| `with_template_title(e, Option(String))`, `with_template_description`, `with_template_mime_type`, `with_template_annotations`                                                 | `with_title(r, String)`, `with_description`, `with_mime_type`, `with_annotations`, plus `with_size`, `with_icons`, `with_meta`, for both kinds |
| `TemplateError`: `InvalidTemplateUri`, `UnsupportedTemplateSyntax`                                                                                                            | same names with the template: `InvalidTemplateUri(template)`, `UnsupportedTemplateSyntax(template)`; `describe_template_error`                 |
| `Resource` record (listing), `ResourceTemplate` record, `client.ResourceDeclaration`, `client.ResourceTemplateDeclaration`                                                    | `resources.Declaration`, `resources.TemplateDeclaration` (read records, with `icons` and `meta`)                                               |
| `ResourceUri`, `resource_uri`, `resource_uri_to_string`, `ResourceError`, `template_description`, `matching_template_reader`, `resource_to_json`, `resource_template_to_json` | removed or internal                                                                                                                            |

```gleam
// Before
let readme =
  resources.resource("memo://readme", "Readme", read)
let assert Ok(notes) = resources.resource_template("memo://notes/{id}", "Note", read_note)
let notes = notes |> resources.with_template_mime_type(Some("text/markdown"))
server |> server.with_resources([readme]) |> server.with_resource_templates([notes])

// After
let readme = resources.static("memo://readme", "Readme", read)
let notes =
  resources.template("memo://notes/{id}", "Note", read_note)
  |> resources.with_mime_type("text/markdown")
server |> server.with_resources([readme, notes])
```

## `relay/prompts`

| Before                                                                                                                                    | After                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `prompt(name, arguments, get) -> ContextPrompt(ctx)`                                                                                      | `prompt(name, arguments, get) -> Prompt(ctx)`; `get` returns `PromptResult`                                                                                                      |
| `prompt_with_inputs(Prompt(..), fn(ctx, args, Option(Value)) -> Result(PromptHandlerResult, PromptError))`                                | `prompt_call(name, arguments, fn(tool.Call(ctx), args) -> Result(tool.Reply(PromptResult), e))`; another round with `tool.request_input`, answers through `tool.input_responses` |
| `Prompt` record, `ContextPrompt`, `ContextPromptWithInputs`, `PromptHandlerResult`, `CompletePrompt`, `RequestPromptInput`, `PromptError` | opaque `Prompt(ctx)`; `with_title`, `with_description`, `with_icons`, `with_meta`                                                                                                |
| `prompt_argument(name, required: Bool)`                                                                                                   | `argument(name)`, `required_argument(name)`; `PromptArgument(name, title, description, required)`                                                                                |
| `PromptResult(description, messages)`                                                                                                     | `PromptResult(description, messages, meta)`                                                                                                                                      |
| —                                                                                                                                         | `user_message(text)`, `assistant_message(text)`                                                                                                                                  |
| `client.PromptDeclaration`                                                                                                                | `prompts.Declaration(name, title, description, arguments, icons, meta)`                                                                                                          |
| `prompt_to_json`, `prompt_argument_to_json`, `prompt_message_to_json`                                                                     | internal                                                                                                                                                                         |

```gleam
// Before
prompts.prompt("review", [prompts.prompt_argument("code", True)], fn(_, args) {
  Ok(prompts.PromptResult(None, [prompts.PromptMessage(content.UserRole, content.text_content(code(args)))]))
})

// After
prompts.prompt("review", [prompts.required_argument("code")], fn(_, args) {
  Ok(prompts.PromptResult(None, [prompts.user_message(code(args))], []))
})
```

## `relay/completion`

| Before                                                                                                       | After                                                                                |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `completion(fn(ctx, CompletionRef, CompletionArgument) -> Result(CompletionValues, e))`                      | `completion(fn(ctx, Request) -> Result(Values, e))`                                  |
| `completion_with_context(fn(ctx, ref, argument, Option(Dict)) -> Result(CompletionValues, CompletionError))` | `completion` (the `Request` carries `context`)                                       |
| `CompletionRef`: `PromptRef(name)`, `ResourceRef(uri_template)`                                              | `Reference`: `PromptReference(name)`, `ResourceReference(uri_template)`              |
| `CompletionArgument(name, value)`                                                                            | `Request(reference, argument: String, value: String, context: Dict(String, String))` |
| `CompletionValues(values, total, has_more)`, `completion_values(values)`                                     | `Values(values, total, has_more)`, `values(values)`                                  |
| `ContextCompletion`, `CompletionError`, `completion_values_to_json`                                          | removed                                                                              |
| `server.with_completion(server, Option(ContextCompletion))`                                                  | `server.with_completion(server, Completion)`                                         |

The wire `context` now has the frozen schema's shape,
`"context": {"arguments": {...}}`, on the server and in `client.complete`.

```gleam
// Before
completion.completion(fn(_, _reference, argument) {
  Ok(completion.completion_values(matches(argument.value)))
})

// After
completion.completion(fn(_, request: completion.Request) {
  Ok(completion.values(matches(request.value)))
})
```

## `relay/subscriptions`

| Before                                                                                                                                             | After                                                                                                                                |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `SubscriptionFilter(tools_list_changed, resources_list_changed, prompts_list_changed, resource_subscriptions)`, `empty_filter`, `filter_supported` | `Notification`: `ToolsListChanged`, `ResourcesListChanged`, `PromptsListChanged`, `ResourceUpdated(uri)`; a list of them is a filter |
| `client.SubscriptionNotification`                                                                                                                  | `subscriptions.Notification`                                                                                                         |

## `relay/server`

`relay/server` now holds only the description. The reducer moved to
`relay/reducer`.

| Before                                                                                                                                                   | After                                                                                                                                                             |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `server(registry)`                                                                                                                                       | `new(tools: List(Tool(ctx)))` (panics on a repeated name)                                                                                                         |
| `with_resources(s, List(ContextResource))`, `with_resource_templates(s, ..)`                                                                             | `with_resources(s, List(Resource(ctx)))` (both kinds)                                                                                                             |
| `with_prompts(s, List(ContextPrompt))`                                                                                                                   | `with_prompts(s, List(Prompt(ctx)))`                                                                                                                              |
| `with_completion(s, Option(ContextCompletion))`                                                                                                          | `with_completion(s, Completion(ctx))`                                                                                                                             |
| `with_dispatch(s, fn(Registry, ctx, ToolName, Value, Option(Value), ProgressReporter) -> ..)`                                                            | removed: authorization is `with_tool_access(s, visible:, callable:)` and `http.new_protected`; wrap work inside the handler                                       |
| —                                                                                                                                                        | `with_tool_access(s, visible: fn(ctx, Declaration) -> Bool, callable: fn(ctx, Declaration) -> Bool)`, `with_info(s, name, version)`, `with_instructions(s, text)` |
| `register_tool(s, ContextTool) -> Result(Server, RegistryError)`                                                                                         | `register_tool(s, Tool) -> Result(Server, RegisterError)` (`DuplicateTool(name)`), `describe_register_error`                                                      |
| `unregister_tool(s, ToolName) -> #(Server, Bool)`                                                                                                        | `unregister_tool(s, name: String) -> Server`; `has_tool(s, name)`                                                                                                 |
| `registered_tools(s) -> List(ContextTool)`                                                                                                               | `tools(s) -> List(tool.Declaration)`                                                                                                                              |
| `http_admission_failure`, `http_custom_headers_valid`, `exchange_is_known`                                                                               | internal to `relay/http` and `relay/reducer`                                                                                                                      |
| `ExchangeId`, `fresh_exchange`, `exchange_id`, `exchange_id_to_int`, `exchange_id_to_string`, `InvocationId`, `fresh_invocation`, `invocation_id_to_int` | `relay/reducer.ExchangeId`, `new_exchange_id`, `exchange_id_to_int`, `InvocationId`, `invocation_id_to_int`; `exchange_id(n)` and `fresh_invocation` removed      |
| `step`, `perform`, `ServerInput`, `ServerEffect`, `Invocation`, `InvocationOutcome`, `UnhandledMessage`, `invocation_*`                                  | `relay/reducer` (see below)                                                                                                                                       |

A hidden, denied and unknown tool now answer the JSON-RPC invalid-params
error immediately, without starting an invocation.

```gleam
// Before
let assert Ok(registry) = tool.registry([search, stock])
let service = server.server(registry)

// After
let service = server.new([search, stock])
```

## `relay/reducer`

| Before (`relay/server`)                                                                                          | After (`relay/reducer`)                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| the `Server` value itself carried reducer state                                                                  | `State(ctx)`: `init(server)`, `server(state)`, `open_streams(state)`                                                                                                                  |
| `step(server, input) -> #(Server, List(ServerEffect))`                                                           | `step(state, input) -> #(State, List(Effect))`                                                                                                                                        |
| `MessageReceived(exchange, context, bytes)`                                                                      | `Received(exchange, context, bytes, correlation: Option(Correlation))`                                                                                                                |
| `InvocationFinished(invocation, outcome)`                                                                        | `Finished(invocation, outcome)` (`Outcome` is opaque; `outcome_status(o) -> telemetry.Status`)                                                                                        |
| `InvocationProgress(invocation, Int)`                                                                            | `Progressed(invocation, progress: Float, total: Option(Float), message: Option(String))`                                                                                              |
| —                                                                                                                | `Crashed(invocation)`, `TimedOut(invocation)`                                                                                                                                         |
| `ExchangeClosed(exchange)`                                                                                       | unchanged                                                                                                                                                                             |
| `NotifyResourceUpdated(uri)`, `NotifyToolsListChanged`, `NotifyResourcesListChanged`, `NotifyPromptsListChanged` | `Notify(subscriptions.Notification)`                                                                                                                                                  |
| `RegisterTool(tool)`, `UnregisterTool(ToolName)`                                                                 | `RegisterTool(tool)`, `UnregisterTool(name: String)`                                                                                                                                  |
| `TerminateSubscription(RequestId)`                                                                               | `EndStreams` (ends every open stream)                                                                                                                                                 |
| `Write`, `StartInvocation`, `CancelInvocation`, `CloseExchange`, `EmitRequestAdmitted`, `SendProgress`, `Ignore` | `Write(exchange, bytes)`, `Start(invocation)`, `Cancel(invocation_id)`, `Close(exchange)`, `Admitted(exchange, method)`; progress arrives as a `Write`; ignored messages only `Close` |
| `perform(invocation)` with `invocation_with_progress`                                                            | `perform(invocation, report_progress: fn(Float, Option(Float), Option(String)) -> Nil)`                                                                                               |
| `invocation_id`, `invocation_exchange`, `invocation_request_id`, `invocation_context`, `invocation_method`       | `invocation_id`, `invocation_exchange`, `invocation_context`, `invocation_method`, `invocation_tool`, `invocation_correlation`; `invocation_request_id` removed                       |
| —                                                                                                                | `signal_cancelled(worker_pid, invocation_id)` fires the handler's `tool.cancelled` selector                                                                                           |

The pagination and input-round key moved from reducer state into the
`Server` value (made by `server.new`), so a cursor from one HTTP request is
valid on the next. The reducer keeps at most about 10,000 closed exchange
records.

## `relay/runtime`

| Before                                                                                                                                                                                        | After                                                                                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RuntimeConfig(max_live_exchanges, max_frame_bytes, invocation_timeout_ms, tombstone_retention_ms)`, `default_config()`                                                                       | opaque `Config`: `config()`, `with_max_live_exchanges(Int)`, `with_max_frame_bytes(Int)`, `with_max_json_depth(Int)`, `with_invocation_timeout(Duration)`, `with_cancellation_grace(Duration)`, `with_tombstone_retention(Duration)`, `with_max_tombstones(Int)`, `with_label(String)`; `max_frame_bytes(config)`, `invocation_timeout(config)` |
| `validate_config(c) -> Result(Nil, RuntimeConfigError)`, `RuntimeConfigError`, `InvalidRuntimeSetting(field, value)`, `RuntimeConfigField` (`InvocationTimeoutMs`, `TombstoneRetentionMs`, …) | `validate(c) -> Result(Config, StartError)`; `ConfigField`: `MaxLiveExchanges`, `MaxFrameBytes`, `MaxJsonDepth`, `InvocationTimeout`, `CancellationGrace`, `TombstoneRetention`, `MaxTombstones`                                                                                                                                                |
| `RuntimeStartError`: `InvalidRuntimeConfig(e)`, `ActorStartFailed(e)`                                                                                                                         | `StartError`: `InvalidConfig(field)`, `ActorStartFailed(e)`; `describe_start_error`                                                                                                                                                                                                                                                             |
| `start(server, config, sink)`                                                                                                                                                                 | unchanged shape                                                                                                                                                                                                                                                                                                                                 |
| —                                                                                                                                                                                             | `supervised(server, config, sink, name)`, `named(name)`                                                                                                                                                                                                                                                                                         |
| `send_frame(rt, exchange, ctx, bytes, timeout_ms) -> Result(Nil, RuntimeError)`                                                                                                               | `send_frame(rt, exchange, ctx, bytes, correlation: Option(Correlation)) -> Result(Nil, FrameError)`                                                                                                                                                                                                                                             |
| `RuntimeError`: `FrameTooLarge`, `TooManyLiveExchanges`, `RuntimeStopped`                                                                                                                     | `FrameError`: same plus `FrameTooDeep(limit)`                                                                                                                                                                                                                                                                                                   |
| `RuntimeOutput`: `OutputWrite`, `OutputClose`                                                                                                                                                 | `Output`: same constructors                                                                                                                                                                                                                                                                                                                     |
| `notify_resource_updated(rt, uri)`, `notify_tools_list_changed`, `notify_resources_list_changed`, `notify_prompts_list_changed`                                                               | `notify(rt, subscriptions.Notification)`                                                                                                                                                                                                                                                                                                        |
| `register_tool(rt, tool)`, `unregister_tool(rt, ToolName)`                                                                                                                                    | `register_tool(rt, tool)`, `unregister_tool(rt, name: String)`                                                                                                                                                                                                                                                                                  |
| `terminate_subscription(rt, RequestId)`                                                                                                                                                       | `end_streams(rt)`                                                                                                                                                                                                                                                                                                                               |
| `stop(rt, timeout_ms)`                                                                                                                                                                        | `stop(rt)` (waits at most 5 s)                                                                                                                                                                                                                                                                                                                  |
| `close(rt)`, `exchange_closed(rt, ex)`                                                                                                                                                        | unchanged                                                                                                                                                                                                                                                                                                                                       |

A cancelled or timed-out handler now sees `tool.cancelled(call)` fire and is
killed after the cancellation grace (5 s).

```gleam
// Before
let config =
  runtime.RuntimeConfig(
    max_live_exchanges: 1,
    max_frame_bytes: limits.max_body_bytes,
    invocation_timeout_ms: limits.request_timeout_ms,
    tombstone_retention_ms: 1000,
  )
let assert Ok(rt) = runtime.start(mcp, config, sink)
let exchange = server.fresh_exchange()
runtime.send_frame(rt, exchange, context, body, limits.request_timeout_ms)
runtime.stop(rt, 1000)

// After
let config =
  runtime.config()
  |> runtime.with_max_live_exchanges(1)
  |> runtime.with_max_frame_bytes(limits.max_body_bytes)
  |> runtime.with_invocation_timeout(duration.milliseconds(limits.timeout_ms))
let assert Ok(rt) = runtime.start(mcp, config, sink)
let exchange = reducer.new_exchange_id()
runtime.send_frame(rt, exchange, context, body, None)
runtime.stop(rt)
```

An application that drove `relay/runtime` from a router to mount MCP
should use `relay/http.handler` and `http.handle` instead (below).

## `relay/telemetry`

Event names are unchanged; three events are new. The `emit_*` helpers are
internal. Metadata records changed:

| Before                                                                                                                                                                                 | After                                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `InvocationStartedMeta(exchange_id, invocation_id, tool_name)` (`tool_name` carried the method)                                                                                        | `InvocationStartedMeta(exchange_id, invocation_id, method, tool: Option(String), correlation, listener)`                                                                                                                                                                                                                                                       |
| `InvocationCompletedMeta(exchange_id, invocation_id, status: String)`                                                                                                                  | `InvocationCompletedMeta(exchange_id, invocation_id, method, tool, status: Status, correlation, listener)`; `Status`: `Succeeded`, `ToolFailed`, `InputRequested`, `Failed`                                                                                                                                                                                    |
| `InvocationCancelledMeta(invocation_id)`                                                                                                                                               | adds `method`, `tool`, `correlation`, `listener`                                                                                                                                                                                                                                                                                                               |
| `InvocationCrashedMeta(invocation_id, reason: String)`                                                                                                                                 | `InvocationCrashedMeta(invocation_id, method, tool, reason: CrashReason, correlation, listener)`; `CrashReason`: `HandlerCrashed`, `HandlerTimedOut`                                                                                                                                                                                                           |
| `FrameRejectedMeta(exchange_id, reason: String)`                                                                                                                                       | `FrameRejectedMeta(exchange_id, problem: FrameProblem, listener)`; `FrameProblem`: `FrameTooLarge`, `TooManyExchanges`, `NestingTooDeep`, `TrailingBytes`                                                                                                                                                                                                      |
| `RequestAdmittedMeta(exchange_id, method)`                                                                                                                                             | adds `correlation`, `listener`                                                                                                                                                                                                                                                                                                                                 |
| `ExchangeClosedMeta(exchange_id)`                                                                                                                                                      | adds `listener`                                                                                                                                                                                                                                                                                                                                                |
| `emit_frame_rejected`, `emit_request_admitted`, `emit_invocation_started`, `emit_invocation_completed`, `emit_invocation_cancelled`, `emit_invocation_crashed`, `emit_exchange_closed` | internal                                                                                                                                                                                                                                                                                                                                                       |
| —                                                                                                                                                                                      | `http_rejected_event()` (`HttpRejectedMeta(status, reason: RejectReason, correlation, listener)`), `authorization_decided_event()` (`AuthorizationDecidedMeta(verifier, decision: Decision, correlation, listener)`), `client_call_event()` (`ClientCallMeasurements(duration_ms)`, `ClientCallMeta(method, tool, outcome: CallOutcome, correlation, client)`) |

```gleam
// Before
use _, meta <- sinal.observe(telemetry.invocation_started_event())
log("tool_name=" <> meta.tool_name)
use measured, meta <- sinal.observe(telemetry.invocation_completed_event())
log(meta.status <> " in " <> int.to_string(measured.duration_ms) <> " ms")

// After
use _, meta <- sinal.observe(telemetry.invocation_started_event())
log("method=" <> meta.method <> " tool=" <> option.unwrap(meta.tool, "-"))
use measured, meta <- sinal.observe(telemetry.invocation_completed_event())
log(string.inspect(meta.status) <> " in " <> int.to_string(measured.duration_ms) <> " ms")
```

## `relay/authorization`

| Before                                                                                                                                                                                                                   | After                                                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `BearerToken`, `bearer_token(raw)`                                                                                                                                                                                       | unchanged; `token_value(token) -> String` is new                                                                                                                                 |
| `Resource`, `resource(raw)`                                                                                                                                                                                              | `ProtectedResource`, `protected_resource(uri)` (an absolute `http`/`https` URI without a fragment); `resource_uri(r)`                                                            |
| `Scope`, `scope(raw)`                                                                                                                                                                                                    | unchanged; `scope_name(s)` is new                                                                                                                                                |
| `BoundaryValueError`: `EmptyBearerToken`, `EmptyResource`, `EmptyScope`                                                                                                                                                  | `ValueError`: `EmptyBearerToken`, `InvalidResource(uri)`, `EmptyScope`                                                                                                           |
| `ProtectionConfig`, `protection_config(resource, scopes)`                                                                                                                                                                | `Protection`, `protection(resource, scopes)`; `with_authorization_servers(p, issuers)`, `protected(p)`, `required_scopes(p)`                                                     |
| `verifier(name, version, verify)`, `verifier_declaration`, `trust_verifier`, `VerifierDeclaration`, `VerifierPurpose`                                                                                                    | `verifier(name, verify)`; `verifier_name(v)`                                                                                                                                     |
| `VerifierAttestation(principal, audiences: List(Resource), scopes: List(Scope))`, `attestation(p, List(Resource), List(Scope))`                                                                                          | opaque `Attestation`, `attestation(principal, audiences: List(String), scopes: List(String))`                                                                                    |
| `VerificationError`                                                                                                                                                                                                      | unchanged                                                                                                                                                                        |
| `AdmissionError`: `VerificationFailed`, `ResourceNotGranted`, `MissingEndpointScope`                                                                                                                                     | adds `MissingToken`                                                                                                                                                              |
| `GrantedRequest`, `granted_principal`, `granted_resource`, `granted_scopes`                                                                                                                                              | `Grant`, `grant_principal`, `grant_resource`, `grant_scopes`, `has_scope(grant, scope)`                                                                                          |
| `admit(verifier, token, config)`                                                                                                                                                                                         | `admit(verifier, token, protection)`                                                                                                                                             |
| —                                                                                                                                                                                                                        | `parse_authorization(header)`, `challenge(protection, error) -> Challenge(status, www_authenticate)`, `metadata_path(p)`, `metadata_url(p)`, `resource_metadata(p) -> json.Json` |
| `ToolPolicy`, `tool_policy`, `Visibility`, `ExecutionAuthorization`, `ProtectedRegistry`, `protect_registry`, `dispatch_granted`, `visible_declarations`, `InaccessibleCause`, `ProtectedDispatchError`, `GrantUseError` | removed: `relay/http.new_protected` admits each request, and `relay/server.with_tool_access` decides visibility and execution from the context                                   |

```gleam
// Before: a verifier rebuilt per request because the token was unreadable
let verifier =
  authorization.verifier("warden-introspection", "1", fn(_opaque) {
    verify(client, raw, now)
  })
authorization.admit(verifier, token, protection)

// After: built once; the verifier reads its token
let verifier =
  authorization.verifier("warden-introspection", fn(token) {
    verify(client, authorization.token_value(token), now)
  })
```

A local JWT validator that returns its subject, audiences and scopes plugs
in as one expression:

```gleam
let verifier = {
  use token <- authorization.verifier("jwt")
  validate(validator, authorization.token_value(token))
  |> result.map(fn(c) { authorization.attestation(c, c.audiences, c.scopes) })
  |> result.replace_error(authorization.BearerRejected)
}
```

## `relay/http`

| Before (`relay/transport/http`)                                                                                                                                  | After (`relay/http`)                                                                                                                                                                                                                                                      |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `listener(server, fn() -> ctx) -> HttpListener(ctx)`                                                                                                             | `new(server: Server(Nil)) -> Config(Nil)`, `new_with_context(server, fn(Request(BitArray)) -> Result(ctx, Response(BytesTree)))`, `new_protected(server, verifier, protection, fn(Request(BitArray), Grant(p)) -> Result(ctx, Response(BytesTree)))`                      |
| `HttpOptions(port, host)`, `with_options`                                                                                                                        | `with_bind(config, host, port)`                                                                                                                                                                                                                                           |
| `HttpPolicy(max_body_bytes, max_response_bytes, request_timeout_ms, sse_keepalive_ms, allowed_hosts, allowed_origins)`, `with_policy`, `local_http_policy(host)` | `with_max_body_bytes(Int)`, `with_max_response_bytes(Int)`, `with_request_timeout(Duration)`, `with_sse_keepalive(Duration)`, `with_allowed_hosts(List(String))`, `with_allowed_origins(List(String))`; the defaults are the old local policy except the keepalive (15 s) |
| —                                                                                                                                                                | `with_max_concurrent_requests(Int)` (1,024), `with_max_listen_streams(Int)` (64), `with_max_json_depth(Int)` (64), `with_correlation(fn(Request) -> Option(Correlation))`, `with_label(String)`                                                                           |
| `with_tls`, `allow_unauthenticated`                                                                                                                              | unchanged, on `Config`                                                                                                                                                                                                                                                    |
| `validate(listener) -> Result(Nil, ListenerError)`, `ListenerError`, `describe_listener_error`                                                                   | `validate(config) -> Result(Nil, StartError)`, `describe_start_error`; `StartError`: `InvalidConfig(field: ConfigField)`, `UnauthenticatedNonLoopbackBind(host)`, `HandlerFailed(e)`, `BindFailed(host, port)`                                                            |
| `start(listener) -> Result(HttpServer(ctx), String)`                                                                                                             | `start(config) -> Result(Handler(ctx), StartError)`, linked to the caller                                                                                                                                                                                                 |
| —                                                                                                                                                                | `handler(config)` (mountable, no listener), `handle(handler, Request(BitArray)) -> Response(BytesTree)`, `mist_handler(handler)`, `supervised(config, name)`, `named(name)`                                                                                               |
| `HttpServer(ctx)`                                                                                                                                                | `Handler(ctx)`                                                                                                                                                                                                                                                            |
| `http_server_port(server)`                                                                                                                                       | `port(handler)`                                                                                                                                                                                                                                                           |
| `stop_http_server(server)`                                                                                                                                       | `stop(handler)`                                                                                                                                                                                                                                                           |
| `notify_resource_updated(s, uri)`, `notify_tools_list_changed`, `notify_resources_list_changed`, `notify_prompts_list_changed`                                   | `notify(handler, subscriptions.Notification)`                                                                                                                                                                                                                             |
| `register_tool(s, ContextTool)`, `unregister_tool(s, ToolName) -> Bool`                                                                                          | `register_tool(handler, Tool) -> Result(Nil, server.RegisterError)`, `unregister_tool(handler, name: String) -> Bool`                                                                                                                                                     |

Behavior: immediate answers (listings, errors) are `application/json` even
when the client accepts SSE; SSE responses use chunked encoding with
`connection: close`; a full endpoint answers 503 with `retry-after`; JSON
nested deeper than 64 answers 400.

```gleam
// Before
let assert Ok(running) =
  server.server(registry)
  |> http.listener(fn() { Nil })
  |> http.with_policy(http.local_http_policy("127.0.0.1"))
  |> http.start
let url = "http://127.0.0.1:" <> int.to_string(http.http_server_port(running)) <> "/"
http.stop_http_server(running)

// After
let assert Ok(running) = http.start(http.new(service))
let url = "http://127.0.0.1:" <> int.to_string(http.port(running)) <> "/"
http.stop(running)
```

Mounting in wisp replaces a hand-written runtime driver:

```gleam
// After: start once
let assert Ok(mcp) =
  http.new_protected(service, verifier, protection, fn(_request, grant) {
    Ok(authorization.grant_principal(grant))
  })
  |> http.with_allowed_hosts(["mcp.example.com"])
  |> http.handler

// After: in the router
["mcp"] -> {
  use body <- wisp.require_bit_array_body(req)
  http.handle(mcp, request.set_body(req, body)) |> response.map(wisp.Bytes)
}
[".well-known", "oauth-protected-resource", "mcp"] ->
  http.handle(mcp, request.set_body(req, <<>>)) |> response.map(wisp.Bytes)
```

## `relay/stdio`

| Before (`relay/transport/stdio`)                                                                                                                                                               | After (`relay/stdio`)                                                                                                                                  |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `run_local_unprotected_stdio_server(server, default_stdio_config(), ctx)`                                                                                                                      | `serve(server, ctx)`; `serve_with(server, ctx, config)`                                                                                                |
| `LocalUnprotectedStdioConfig(chunk_size, runtime_config)`, `default_stdio_config()`                                                                                                            | opaque `Config`: `config()`, `with_chunk_size(Int)`, `with_runtime(runtime.Config)`                                                                    |
| `StdioError`: `InvalidChunkSize(Int)`, `InvalidRuntimeConfig(RuntimeConfigError)`, `IoError(String)`, `StdoutBroken(String)`, `StartupFailed(String)`, `OversizedFrame`, `InvalidTrailingData` | `InvalidChunkSize(size)`, `InvalidRuntimeConfig(field)`, `ReadFailed`, `StdoutBroken`, `StartupFailed`, `InvalidTrailingData(bytes)`; `describe_error` |
| `ReadOutcome`, `FramerResult`, `Framer`, `new_framer`, `feed_framer`, `finish_framer`, `Writer`, `start_writer`, `write_bytes`, `stop_writer`, `stream_read_loop`, `log_stderr`                | internal (`relay/internal/stdio_frames`); `log_stderr` removed                                                                                         |

```gleam
// Before
let assert Ok(Nil) =
  stdio.run_local_unprotected_stdio_server(service, stdio.default_stdio_config(), Nil)

// After
let assert Ok(Nil) = stdio.serve(service, Nil)
```

## `relay/client`

| Before                                                                                                                                                                                                                                                             | After                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_config(url) -> Result(HttpClientConfig, ClientError)`, `HttpClientConfig`                                                                                                                                                                                    | `http(url) -> Result(Config, Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `stdio_config(exe, args) -> StdioConfig` (public record)                                                                                                                                                                                                           | `stdio(exe, args) -> Config` (the command is held in a closure and does not print)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| —                                                                                                                                                                                                                                                                  | `in_process(server, context) -> Config`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `connect_http(config)`, `connect_stdio(config)`                                                                                                                                                                                                                    | `connect(config) -> Result(Client, Error)`; HTTP connects lazily, so an unreachable server fails on the first call                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `with_timeout(c, Int)`                                                                                                                                                                                                                                             | `with_timeout(c, Duration)`; `with_connect_timeout(c, Duration)` (10 s)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `with_max_response_bytes`, `with_ca_cert_file`, `with_input_methods`                                                                                                                                                                                               | unchanged names; input methods are `tool.InputMethod`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `ListingLimits(max_pages, max_items)`, `default_listing_limits`, `with_listing_limits(c, ListingLimits)`                                                                                                                                                           | `with_listing_limits(c, pages, items)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| —                                                                                                                                                                                                                                                                  | `with_headers(c, fn() -> List(#(String, String)))`, `allow_plaintext_headers`, `with_http_client(c, http_gun.Client)`, `with_max_pending_calls(c, Int)`, `with_label(c, String)`                                                                                                                                                                                                                                                                                                                                                                                                  |
| —                                                                                                                                                                                                                                                                  | views: `with_deadline(client, http_gun/deadline.Deadline)`, `with_cancellation(client, http_gun/cancellation.Token)`, `with_correlation(client, Correlation)`                                                                                                                                                                                                                                                                                                                                                                                                                     |
| `ClientError`: `InvalidClientConfiguration`, `ConnectionFailed(String)`; `TransportError`: `ConnectionClosed`, `RequestCancelled`, `RequestTimedOut`, `ResponseLimitExceeded`, `TransportFault(String)`; operations returning `Result(_, String)`                  | one `Error`: `InvalidConfig(field)`, `ConnectFailed`, `Refused`, `TimedOut(evidence)`, `Cancelled(evidence)`, `ConnectionClosed(evidence)`, `ResponseTooLarge(limit)`, `TooManyPendingCalls(limit)`, `HttpStatus(status, www_authenticate)`, `RpcError(code, message, data)`, `MalformedResponse(detail)`, `UnsupportedVersion(supported)`, `UnsupportedInputRequest(method)`, `InvalidArguments(detail)`, `InvalidInputResponses`, `ListingLimitExceeded(limit)`; `Evidence` (`NotSent`, `MaybeSent`, `Completed`), `kind`, `evidence`, `is_retryable`, `name`, `describe_error` |
| `call_definition(peer, d, input) -> ToolCallOutcome(o)`                                                                                                                                                                                                            | `call(peer, d, input) -> Result(ToolResult(o), Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `ToolCallOutcome`: `StructuredSuccess(o, content)`, `ContentOnlySuccess(content)`, `ToolFailure(content)`, `InputRequired(continuation, requests)`, `ProtocolFailure(String)`, `TransportFailure(TransportError)`, `InputEncodingFailure`, `InvalidInputResponses` | `ToolResult`: `Succeeded(output, content)`, `ToolFailed(content, structured)`, `InputRequired(continuation, requests)`; the failures are `Error` values                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `call_content_definition`, `ContentCallOutcome`, `ContentContinuation`, `resume_content`                                                                                                                                                                           | `call` with a content definition (the output is the content)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `resume_tool(continuation, responses)`, `ToolContinuation`                                                                                                                                                                                                         | `resume(continuation, responses)`, `Continuation`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `call_discovered(peer, client.ToolDeclaration, Value) -> ToolCallOutcome(Value)`                                                                                                                                                                                   | `call_discovered(peer, tool.Declaration, Value) -> Result(ToolResult(Value), Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `discover(peer) -> Result(Discovery, String)`, `Discovery(server_info, supported_versions, capabilities: Dynamic)`                                                                                                                                                 | `Result(Discovery, Error)`, `Discovery(server_info, supported_versions, capabilities: Value, instructions)`, `has_capability(d, name)`                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `list_tools -> Result(List(client.ToolDeclaration), String)`                                                                                                                                                                                                       | `Result(List(tool.Declaration), Error)`; `input_schema` is a `Value`, and `tool.input_contract` loads it                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `list_resources`, `list_resource_templates`, `list_prompts`                                                                                                                                                                                                        | return `resources.Declaration`, `resources.TemplateDeclaration`, `prompts.Declaration`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `list_tools_json`, `list_resources_json`, `list_resource_templates_json`, `list_prompts_json`                                                                                                                                                                      | `list_raw(peer, method, collection) -> Result(List(Value), Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `raw_json_call(peer, method, name, params) -> Result(BitArray, String)`                                                                                                                                                                                            | `call_raw(peer, method, name, params) -> Result(Value, Error)` (the result object)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `read_resource`, `get_prompt`                                                                                                                                                                                                                                      | `Result(_, Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `complete(peer, ref, argument, Option(context))`                                                                                                                                                                                                                   | `complete(peer, completion.Request)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `listen(peer, SubscriptionFilter) -> Result(Subscription, String)`                                                                                                                                                                                                 | `listen(peer, List(subscriptions.Notification)) -> Result(Subscription, Error)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `acknowledged_notifications(sub) -> SubscriptionFilter`                                                                                                                                                                                                            | `listening(sub) -> List(Notification)`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `next_notification(sub, timeout_ms) -> Result(SubscriptionNotification, String)`                                                                                                                                                                                   | `next_notification(sub, wait: Duration) -> Result(Option(Notification), Error)` (`None`: nothing within the wait)                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `close_subscription`, `close`, `ServerInfo`                                                                                                                                                                                                                        | unchanged                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `ToolDeclaration`, `ResourceDeclaration`, `ResourceTemplateDeclaration`, `PromptDeclaration`, `Annotations`, `Icon`, `IconTheme`, `InputMethod`, `SubscriptionNotification`                                                                                        | `tool.Declaration`, `resources.Declaration`, `resources.TemplateDeclaration`, `prompts.Declaration`, `content.Annotations`, `content.Icon`, `content.IconTheme`, `tool.InputMethod`, `subscriptions.Notification`                                                                                                                                                                                                                                                                                                                                                                 |

A deadline or a cancellation that ends an HTTP call closes that call's
connection, which MCP `2026-07-28` defines as cancellation, so the server
stops the handler; the next call reconnects.

```gleam
// Before
let assert Ok(config) = client.http_config(url)
let assert Ok(peer) = config |> client.with_timeout(2000) |> client.connect_http
case client.call_definition(peer, definition, input) {
  client.StructuredSuccess(output, _) -> Ok(output)
  client.ToolFailure(blocks) -> Error(Failed(text(blocks)))
  client.TransportFailure(client.RequestTimedOut) -> Error(Lost)
  client.TransportFailure(_) -> Error(Unreachable)
  client.ProtocolFailure(reason) -> Error(Protocol(reason))
  _ -> Error(Other)
}

// After
let assert Ok(config) = client.http(url)
let assert Ok(peer) =
  config |> client.with_timeout(duration.seconds(2)) |> client.connect
case client.call(peer, definition, input) {
  Ok(client.Succeeded(output, _)) -> Ok(output)
  Ok(client.ToolFailed(blocks, _)) -> Error(Failed(text(blocks)))
  Ok(client.InputRequired(..)) -> Error(NeedsInput)
  Error(error) ->
    case client.kind(error), client.evidence(error) {
      client.Unreachable, client.NotSent -> Error(Unreachable)
      client.Timeout, _ | client.Unreachable, _ -> Error(Lost)
      _, _ -> Error(Protocol(client.describe_error(error)))
    }
}
```

```gleam
// After: a bearer token per request, a deadline and cancellation per call
let assert Ok(config) = client.http("https://mcp.example.com/mcp")
let assert Ok(peer) =
  config
  |> client.with_headers(fn() { [#("authorization", "Bearer " <> token())] })
  |> client.connect
use token <- cancellation.with_token
peer
|> client.with_deadline(deadline.after(duration.seconds(10)))
|> client.with_cancellation(token)
|> client.call(definition, input)
```

## `relay/testing`

New:

- `connect(server, context) -> client.Client`: a client wired to the server
  in this VM through its own runtime;
- `request(method, params) -> Request(BitArray)`: an MCP POST with metadata
  and routing headers, for `http.handle`;
- `body_text(response) -> String`;
- `verifier(tokens)`, `unavailable_verifier()`.

## Dependents

Only the composition apps use Relay. fabric's `fabric_mcp` does not; FABRIC-R10
replaces it with a Relay adapter in wave 5, which builds on `tool.name`,
`tool.input_codec`, `tool.output_codec`, `tool.declaration`, `client.call`,
`client.call_discovered`, `client.list_tools`, `tool.input_contract`, the
client views and `client.Error`. `oversight/playground/ecosystem_pilot`
already fails to compile against llm_wire and is superseded by tool_hub.

### `oversight/apps/tool_hub`

| File                              | Symbols used                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Change                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `src/tool_hub/inventory.gleam`    | `tool.tool_name`, `tool.definition`, `tool.with_description`, `tool.with_annotations`, `tool.empty_annotations`, `tool.with_read_only_hint`, `tool.with_idempotent_hint`, `tool.ToolAnnotations`, `tool.ContextTool`, `tool.handle`, `tool.handle_with_error_renderer`, `tool.registry`, `server.server`, `http.listener`, `http.start`, `http.HttpServer`, `http.http_server_port`                                                                                                                                                                                                                                                                                                                                                                                | `tool.define` with hint setters (`with_read_only_hint(True)`); `Tool`; renderer returns `tool.error_message(..)`; `server.new(tools)`; `http.start(http.new(service))`; `http.Handler`; `http.port`                                                                                                                                                                                                                                                                |
| `src/tool_hub/assistant.gleam`    | `tool.tool_name`, `tool.definition`, `tool.with_description`, `tool.handle_with_error_renderer`, `tool.registry`, `server.server`, `http.listener`, `http.with_policy`, `http.HttpPolicy`, `http.start`, `http.HttpServer`, `client.Client`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | as above; the policy becomes setters on `http.Config` (pass a `fn(http.Config(Nil)) -> http.Config(Nil)` or the values)                                                                                                                                                                                                                                                                                                                                            |
| `src/tool_hub.gleam`              | `client.http_config`, `client.with_timeout(2000)`, `client.connect_http`, `client.call_definition`, `client.StructuredSuccess`, `client.ToolFailure`, `client.list_tools`, `client.close`, `client.Client`, `http.local_http_policy`, `http.HttpPolicy`, `http.HttpServer`, `http.stop_http_server`                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `client.http`, `client.with_timeout(duration.seconds(2))`, `client.connect`, `client.call` with `Ok(client.Succeeded(..))` / `Ok(client.ToolFailed(..))`; `http.stop`                                                                                                                                                                                                                                                                                              |
| `src/tool_hub/remote_tools.gleam` | `tool.definition_metadata`, `tool.definition_name`, `tool.tool_name_to_string`, `tool.definition_input_codec`, `tool.definition_output_codec`, `tool.ToolAnnotations(read_only_hint: ..)`, `client.call_definition`, `client.call_discovered`, `client.list_tools`, `client.ToolDeclaration`, `client.ToolCallOutcome`, `client.StructuredSuccess`, `client.ContentOnlySuccess`, `client.ToolFailure`, `client.TransportFailure`, `client.ProtocolFailure`, `client.InputEncodingFailure`, `client.InputRequired`, `client.InvalidInputResponses`, `client.TransportError`, `client.ConnectionClosed`, `client.RequestCancelled`, `client.RequestTimedOut`, `client.ResponseLimitExceeded`, `client.TransportFault`, `content.ContentBlock`, `content.TextContent` | `tool.declaration`, `tool.name`, `tool.input_codec`, `tool.output_codec`; `declaration.annotations.read_only_hint`; `tool.Declaration`; `Result(client.ToolResult(o), client.Error)`; the transport mapping becomes `client.kind` / `client.evidence` (TH-4: `NotSent` failures are safe to retry); `TextContent(text, _, _)` gains `meta`. The remote input schema is a `Value` (`tool.input_contract`), so the render-and-reparse step goes (RELAY-R4 follow-up) |
| `src/tool_hub/telemetry.gleam`    | `telemetry.request_admitted_event`, `invocation_started_event` (`m.tool_name`), `invocation_completed_event` (`m.status` as `String`), `invocation_cancelled_event`, `invocation_crashed_event` (`m.reason` as `String`), `exchange_closed_event`, `frame_rejected_event` (`m.reason`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | `m.method` and `m.tool`; `m.status` is `telemetry.Status`; crashed `m.reason` is `CrashReason`; frame rejected `m.problem`; correlation now arrives in `m.correlation` when the transport sets `http.with_correlation`                                                                                                                                                                                                                                             |
| `test/tool_hub_test.gleam`        | `client.call_definition`, `client.StructuredSuccess`, `client.ToolFailure`, `client.TransportFailure`, `client.RequestTimedOut`, `client.ToolCallOutcome`, `client.list_tools`, `client.close`, `client.Client`, `content.TextContent`, `content.ContentBlock`, `http.HttpServer`, `http.http_server_port`, `http.stop_http_server`                                                                                                                                                                                                                                                                                                                                                                                                                                | as above; a client timeout now closes the call's connection and cancels the server's run (TH-2), so `relay_client_timeout_leaves_the_run_going_until_close_test` should assert the run stops without `client.close`; cancel one call with `client.with_cancellation`                                                                                                                                                                                               |

### `oversight/apps/secure_mcp`

| File                                                  | Symbols used                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Change                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/secure_mcp/mcp_mount.gleam`                      | `runtime.RuntimeConfig`, `runtime.start`, `runtime.send_frame`, `runtime.stop`, `runtime.OutputWrite`, `runtime.OutputClose`, `server.fresh_exchange`, `server.http_admission_failure`, `server.ExchangeId`, `server.Server`                                                                                                                                                                                                                                                                                                                      | delete the module (SMCP-2): `http.new_protected(..)                                                                                                                                                                                                                                                                                                                                                                                       | > http.handler`once,`http.handle(mcp, request.set_body(req, body))  | > response.map(wisp.Bytes)` per request; Host/Origin, routing headers, status mapping and caps come with it |
| `src/secure_mcp/auth.gleam`                           | `authorization.bearer_token`, `authorization.verifier`, `authorization.admit`, `authorization.attestation`, `authorization.resource`, `authorization.scope`, `authorization.ProtectionConfig`, `authorization.GrantedRequest`, `authorization.VerifierAttestation`, `authorization.Scope`, `authorization.VerificationError`, `authorization.VerificationFailed`, `authorization.BearerRejected`, `authorization.VerifierUnavailable`, `authorization.VerifierUnmapped`, `authorization.ResourceNotGranted`, `authorization.MissingEndpointScope` | build the verifier once with `authorization.verifier(name, fn(token) { .. authorization.token_value(token) .. })` (SMCP-3); `attestation(principal, audiences: List(String), scopes: List(String))`; `Protection`, `Grant`, `Attestation`; the challenge (41 lines) becomes `authorization.challenge` and the metadata `authorization.resource_metadata`, both served by `new_protected`; `scope_name` replaces the comparison workaround |
| `src/secure_mcp/app.gleam`                            | `authorization.protection_config`, `authorization.resource`, `authorization.scope`, `authorization.ProtectionConfig`, `server.server`                                                                                                                                                                                                                                                                                                                                                                                                             | `authorization.protection(authorization.protected_resource(uri), scopes)                                                                                                                                                                                                                                                                                                                                                                  | > authorization.with_authorization_servers([issuer])`; `server.new` |
| `src/secure_mcp/web.gleam`                            | `authorization.granted_principal`, `authorization.ProtectionConfig`, `server.exchange_id_to_int`, `server.Server`                                                                                                                                                                                                                                                                                                                                                                                                                                 | `grant_principal` arrives in the context builder; correlation joins through `http.with_correlation` and `tool.correlation(call)` / `tool.invocation_id(call)` instead of `exchange_id_to_int` (SMCP-9)                                                                                                                                                                                                                                    |
| `src/secure_mcp/tools.gleam`                          | `tool.tool_name`, `tool.definition`, `tool.with_description`, `tool.with_annotations`, `tool.empty_annotations`, `tool.with_read_only_hint`, `tool.handle_advanced_with_error_renderer`, `tool.HandlerResult`, `tool.Complete`, `tool.Registry`, `tool.registry`                                                                                                                                                                                                                                                                                  | `tool.define` + `with_read_only_hint(True)`; `tool.handle_call` returning `tool.complete(..)`; `server.new(tools)`                                                                                                                                                                                                                                                                                                                        |
| `src/secure_mcp/telemetry.gleam`                      | `telemetry.request_admitted_event`, `invocation_started_event` (`m.tool_name`), `invocation_completed_event` (`m.status`), `invocation_crashed_event`, `frame_rejected_event` (`m.reason`)                                                                                                                                                                                                                                                                                                                                                        | as for tool_hub; add `telemetry.authorization_decided_event` for admission decisions                                                                                                                                                                                                                                                                                                                                                      |
| `src/secure_mcp/client.gleam` (raw client, 109 lines) | none (raw HTTP)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | replace with `client.http(url)                                                                                                                                                                                                                                                                                                                                                                                                            | > client.with_headers(..)                                           | > client.connect`(SMCP-6); a 401 arrives as`client.HttpStatus(401, Some(challenge))`                        |
| `test/secure_mcp_test.gleam`                          | `client.http_config`, `client.with_timeout`, `client.connect_http`, `client.discover`, `client.close`                                                                                                                                                                                                                                                                                                                                                                                                                                             | `client.http`, `client.with_timeout(Duration)`, `client.connect`; `relay_client_cannot_authenticate_test` becomes a passing test with `with_headers`                                                                                                                                                                                                                                                                                      |
