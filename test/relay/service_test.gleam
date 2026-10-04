import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/value
import relay/client
import relay/completion
import relay/content
import relay/internal/jsonrpc
import relay/internal/subscriptions_state as subscription_state
import relay/prompts
import relay/reducer
import relay/resources
import relay/server
import relay/subscriptions
import relay/testing
import relay/tool

pub type ApplicationFailure {
  Denied
}

// --- handler errors ----------------------------------------------------------

pub fn service_handler_errors_map_to_json_rpc_errors_test() {
  let srv =
    server.new([])
    |> server.with_resources([
      resources.static("urn:private", "private", fn(_ctx: Nil, _uri) {
        Error(Denied)
      }),
    ])
    |> server.with_prompts([
      prompts.prompt("private", [], fn(_ctx: Nil, _arguments) { Error(Denied) }),
    ])
    |> server.with_completion(
      completion.completion(fn(_ctx: Nil, _request) { Error(Denied) }),
    )
  let peer = testing.connect(srv, Nil)
  let assert Error(client.RpcError(-32_002, resource_message, _, ..)) =
    client.read_resource(peer, "urn:private")
  string.contains(resource_message, "Denied") |> should.be_false
  let assert Error(client.RpcError(-32_602, prompt_message, _, ..)) =
    client.get_prompt(peer, "private", dict.new())
  string.contains(prompt_message, "Denied") |> should.be_false
  let assert Error(client.RpcError(-32_603, completion_message, _, ..)) =
    client.complete(
      peer,
      completion.Request(
        completion.PromptReference("private"),
        "input",
        "a",
        dict.new(),
      ),
    )
  string.contains(completion_message, "Denied") |> should.be_false
  // An unknown resource and an unknown prompt fail the same way.
  let assert Error(client.RpcError(-32_002, _, _, ..)) =
    client.read_resource(peer, "urn:missing")
  let assert Error(client.RpcError(-32_602, _, _, ..)) =
    client.get_prompt(peer, "missing", dict.new())
  client.close(peer)
}

pub fn completion_without_a_handler_is_method_not_found_test() {
  let peer = testing.connect(server.new([]), Nil)
  let assert Error(client.RpcError(-32_601, _, _, ..)) =
    client.complete(
      peer,
      completion.Request(completion.PromptReference("p"), "a", "", dict.new()),
    )
  client.close(peer)
}

// --- the sample server, through the reducer ----------------------------------

fn sample_server() -> server.Server(String) {
  let resource =
    resources.static("memory://notes/1", "note", fn(_context, uri) {
      Ok([content.TextResourceContents(uri, "the note", Some("text/plain"), [])])
    })
  let template =
    resources.template("memory://notes/{id}", "note by id", fn(_context, uri) {
      Ok([content.text_resource(uri, "templated note")])
    })
  let prompt =
    prompts.prompt("welcome", [], fn(_context, _arguments) {
      Ok(prompts.PromptResult(None, [prompts.user_message("hello")], []))
    })
  let completer =
    completion.completion(fn(_context, request: completion.Request) {
      let audience = dict.get(request.context, "audience") |> result_or("")
      Ok(completion.Values(
        [request.value, request.value <> "-next", audience],
        Some(3),
        Some(False),
      ))
    })
  server.new([])
  |> server.with_resources([resource, template])
  |> server.with_prompts([prompt])
  |> server.with_completion(completer)
}

fn result_or(found: Result(a, Nil), default: a) -> a {
  case found {
    Ok(found) -> found
    Error(Nil) -> default
  }
}

fn wire_request(
  method: String,
  fields: List(#(String, json.Json)),
) -> BitArray {
  let metadata =
    json.object([
      #("io.modelcontextprotocol/protocolVersion", json.string("2026-07-28")),
      #("io.modelcontextprotocol/clientCapabilities", json.object([])),
    ])
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.int(1)),
    #("method", json.string(method)),
    #("params", json.object([#("_meta", metadata), ..fields])),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn response_text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(bytes)
  text
}

fn receive(
  state: reducer.State(String),
  method: String,
  fields: List(#(String, json.Json)),
) -> #(reducer.State(String), List(reducer.Effect(String))) {
  reducer.step(
    state,
    reducer.Received(
      reducer.new_exchange_id(),
      "tenant",
      wire_request(method, fields),
      None,
    ),
  )
}

pub fn modern_catalog_lists_test() {
  let state = reducer.init(sample_server())
  let #(state, effects) = receive(state, "resources/list", [])
  let assert [
    reducer.Admitted(_, "resources/list"),
    reducer.Write(_, bytes),
    reducer.Close(_),
  ] = effects
  let text = response_text(bytes)
  should.be_true(string.contains(text, "memory://notes/1"))
  should.be_true(string.contains(text, "\"name\":\"note\""))
  should.be_false(string.contains(text, "memory://notes/{id}"))

  let #(_state, effects) = receive(state, "resources/templates/list", [])
  let assert [
    reducer.Admitted(_, "resources/templates/list"),
    reducer.Write(_, bytes),
    reducer.Close(_),
  ] = effects
  let text = response_text(bytes)
  should.be_true(string.contains(text, "memory://notes/{id}"))
  should.be_false(string.contains(text, "\"uri\":\"memory://notes/1\""))
}

fn invoke_and_get_response(
  state: reducer.State(String),
  method: String,
  fields: List(#(String, json.Json)),
) -> #(reducer.State(String), String) {
  let #(state, effects) = receive(state, method, fields)
  let assert [reducer.Admitted(_, admitted_method), reducer.Start(invocation)] =
    effects
  admitted_method |> should.equal(method)
  reducer.invocation_context(invocation) |> should.equal("tenant")
  let #(state, effects) =
    reducer.step(state, reducer.perform(invocation, fn(_, _, _) { Nil }))
  let assert [reducer.Write(_, bytes), reducer.Close(_)] = effects
  #(state, response_text(bytes))
}

pub fn resources_prompts_completion_invocations_test() {
  let state = reducer.init(sample_server())
  let #(state, read_response) =
    invoke_and_get_response(state, "resources/read", [
      #("uri", json.string("memory://notes/1")),
    ])
  should.be_true(string.contains(read_response, "the note"))
  should.be_true(string.contains(read_response, "text/plain"))

  let #(state, prompt_response) =
    invoke_and_get_response(state, "prompts/get", [
      #("name", json.string("welcome")),
      #("arguments", json.object([])),
    ])
  should.be_true(string.contains(prompt_response, "hello"))

  let #(_state, completion_response) =
    invoke_and_get_response(state, "completion/complete", [
      #(
        "ref",
        json.object([
          #("type", json.string("ref/prompt")),
          #("name", json.string("welcome")),
        ]),
      ),
      #(
        "argument",
        json.object([
          #("name", json.string("topic")),
          #("value", json.string("greeting")),
        ]),
      ),
      #(
        "context",
        json.object([
          #("arguments", json.object([#("audience", json.string("team"))])),
        ]),
      ),
    ])
  should.be_true(string.contains(completion_response, "greeting-next"))
  should.be_true(string.contains(completion_response, "\"team\""))
  should.be_true(string.contains(completion_response, "\"total\":3"))
  should.be_true(string.contains(completion_response, "\"hasMore\":false"))
}

pub fn template_resource_read_test() {
  let #(_state, response) =
    invoke_and_get_response(reducer.init(sample_server()), "resources/read", [
      #("uri", json.string("memory://notes/42")),
    ])
  should.be_true(string.contains(response, "templated note"))
  should.be_true(string.contains(response, "memory://notes/42"))
}

pub fn discovery_advertises_only_delivered_capabilities_test() {
  let #(_state, effects) =
    receive(reducer.init(sample_server()), "server/discover", [])
  let assert [_, reducer.Write(_, bytes), _] = effects
  let assert Ok(capabilities) =
    json.parse(
      response_text(bytes),
      decode.at(
        ["result", "capabilities"],
        decode.dict(decode.string, decode.dynamic),
      ),
    )
  dict.has_key(capabilities, "completions") |> should.be_true
  dict.has_key(capabilities, "resources") |> should.be_true
  dict.has_key(capabilities, "prompts") |> should.be_true
  dict.has_key(capabilities, "logging") |> should.be_false

  // A server without completion does not advertise it.
  let peer = testing.connect(server.new([]), Nil)
  let assert Ok(discovery) = client.discover(peer)
  client.has_capability(discovery, "completions") |> should.be_false
  client.close(peer)
}

pub fn subscription_streams_are_idempotent_and_owner_scoped_test() {
  let filter =
    subscription_state.filter_of([
      subscriptions.ResourceUpdated("memory://notes/42"),
    ])
  let id = jsonrpc.RequestInteger(1)
  let store =
    subscription_state.new()
    |> subscription_state.listen("client-a", id, filter)
    |> subscription_state.listen("client-a", id, filter)
    |> subscription_state.listen("client-b", id, filter)
  subscription_state.count(store) |> should.equal(2)
  subscription_state.subscribers(
    store,
    subscriptions.ResourceUpdated("memory://notes/42"),
  )
  |> list.map(fn(entry) { entry.0 })
  |> list.sort(string.compare)
  |> should.equal(["client-a", "client-b"])
  subscription_state.subscribers(
    store,
    subscriptions.ResourceUpdated("memory://notes/1"),
  )
  |> should.equal([])

  let store = subscription_state.close_stream(store, "client-a", id)
  subscription_state.subscribers(
    store,
    subscriptions.ResourceUpdated("memory://notes/42"),
  )
  |> should.equal([#("client-b", id)])
  let store = subscription_state.close_stream(store, "client-b", id)
  subscription_state.count(store) |> should.equal(0)
}

fn many_resources(count: Int) -> List(resources.Resource(String)) {
  int.range(from: 1, to: count + 1, with: [], run: list.prepend)
  |> list.map(fn(n) {
    resources.static(
      "memory://items/" <> int.to_string(n),
      "item-" <> int.to_string(n),
      fn(_context, uri) { Ok([content.text_resource(uri, "body")]) },
    )
  })
}

pub fn pagination_cursor_is_opaque_and_family_scoped_test() {
  let state =
    reducer.init(server.new([]) |> server.with_resources(many_resources(101)))
  let #(state, effects) = receive(state, "resources/list", [])
  let assert [_, reducer.Write(_, bytes), _] = effects
  let text = response_text(bytes)
  should.be_true(string.contains(text, "\"nextCursor\""))
  let assert Ok(cursor) =
    json.parse(text, decode.at(["result", "nextCursor"], decode.string))

  let #(state, effects) =
    receive(state, "resources/list", [#("cursor", json.string(cursor))])
  let assert [_, reducer.Write(_, bytes), _] = effects
  should.be_true(string.contains(response_text(bytes), "memory://items/1\""))

  let #(_, effects) =
    receive(state, "prompts/list", [#("cursor", json.string(cursor))])
  let assert [reducer.Write(_, bytes), reducer.Close(_)] = effects
  should.be_true(string.contains(response_text(bytes), "-32602"))

  // The client follows every page.
  let peer =
    testing.connect(
      server.new([]) |> server.with_resources(many_resources(101)),
      "tenant",
    )
  let assert Ok(listed) = client.list_resources(peer)
  list.length(listed) |> should.equal(101)
  client.close(peer)
}

// --- resources ---------------------------------------------------------------

pub fn static_and_template_resources_share_one_list_test() {
  let peer = testing.connect(sample_server(), "tenant")
  let assert Ok([static_declaration]) = client.list_resources(peer)
  static_declaration.uri |> should.equal("memory://notes/1")
  let assert Ok([template_declaration]) = client.list_resource_templates(peer)
  template_declaration.uri_template |> should.equal("memory://notes/{id}")
  client.read_resource(peer, "memory://notes/1")
  |> should.equal(
    Ok([
      content.TextResourceContents(
        "memory://notes/1",
        "the note",
        Some("text/plain"),
        [],
      ),
    ]),
  )
  client.read_resource(peer, "memory://notes/7")
  |> should.equal(
    Ok([content.text_resource("memory://notes/7", "templated note")]),
  )
  client.close(peer)
}

pub fn resource_setters_show_in_listings_test() {
  let annotations =
    content.Annotations(
      audience: [content.UserRole],
      priority: Some(1.0),
      last_modified: Some("2026-01-01T00:00:00Z"),
    )
  let icon =
    content.Icon(
      "https://example.com/r.png",
      Some("image/png"),
      ["16x16"],
      None,
    )
  let meta = [#("example.com/owner", value.String("docs"))]
  let resource =
    resources.static("memo://readme", "readme", fn(_ctx: Nil, uri) {
      Ok([content.blob_resource(uri, <<1, 2, 3>>)])
    })
    |> resources.with_title("Readme")
    |> resources.with_description("The project readme")
    |> resources.with_mime_type("text/markdown")
    |> resources.with_size(3)
    |> resources.with_annotations(annotations)
    |> resources.with_icons([icon])
    |> resources.with_meta(meta)
  let peer =
    testing.connect(server.new([]) |> server.with_resources([resource]), Nil)
  client.list_resources(peer)
  |> should.equal(
    Ok([
      resources.Declaration(
        uri: "memo://readme",
        name: "readme",
        title: Some("Readme"),
        description: Some("The project readme"),
        mime_type: Some("text/markdown"),
        size: Some(3),
        annotations: Some(annotations),
        icons: [icon],
        meta: meta,
      ),
    ]),
  )
  client.read_resource(peer, "memo://readme")
  |> should.equal(Ok([content.blob_resource("memo://readme", <<1, 2, 3>>)]))
  client.close(peer)
}

// --- prompts -----------------------------------------------------------------

pub fn prompt_arguments_meta_and_listing_test() {
  let icon = content.icon("https://example.com/p.png")
  let review =
    prompts.prompt(
      "review",
      [
        prompts.required_argument("code"),
        prompts.PromptArgument(
          ..prompts.argument("style"),
          title: Some("Style"),
          description: Some("Review style"),
        ),
      ],
      fn(_ctx: Nil, arguments) {
        case dict.get(arguments, "code") {
          Error(Nil) -> Error(Denied)
          Ok(code) ->
            Ok(
              prompts.PromptResult(
                Some("A code review"),
                [
                  prompts.user_message("Review:\n" <> code),
                  prompts.assistant_message(
                    dict.get(arguments, "style") |> result_or("plain"),
                  ),
                ],
                [#("example.com/prompt", value.String("review"))],
              ),
            )
        }
      },
    )
    |> prompts.with_title("Code review")
    |> prompts.with_description("Reviews code")
    |> prompts.with_icons([icon])
    |> prompts.with_meta([#("example.com/kind", value.String("review"))])
  prompts.argument("x")
  |> should.equal(prompts.PromptArgument("x", None, None, False))
  prompts.required_argument("x")
  |> should.equal(prompts.PromptArgument("x", None, None, True))

  let peer =
    testing.connect(server.new([]) |> server.with_prompts([review]), Nil)
  client.list_prompts(peer)
  |> should.equal(
    Ok([
      prompts.Declaration(
        name: "review",
        title: Some("Code review"),
        description: Some("Reviews code"),
        arguments: [
          prompts.PromptArgument("code", None, None, True),
          prompts.PromptArgument(
            "style",
            Some("Style"),
            Some("Review style"),
            False,
          ),
        ],
        icons: [icon],
        meta: [#("example.com/kind", value.String("review"))],
      ),
    ]),
  )
  client.get_prompt(
    peer,
    "review",
    dict.from_list([#("code", "x = 1"), #("style", "strict")]),
  )
  |> should.equal(
    Ok(
      prompts.PromptResult(
        Some("A code review"),
        [
          prompts.PromptMessage(
            content.UserRole,
            content.text("Review:\nx = 1"),
          ),
          prompts.PromptMessage(content.AssistantRole, content.text("strict")),
        ],
        [#("example.com/prompt", value.String("review"))],
      ),
    ),
  )
  // The handler's error is an invalid-params error.
  let assert Error(client.RpcError(-32_602, _, _, ..)) =
    client.get_prompt(peer, "review", dict.new())
  client.close(peer)
}

pub fn prompt_call_runs_an_input_round_test() {
  let seen = process.new_subject()
  let asking =
    prompts.prompt_call("asking", [prompts.argument("topic")], fn(call, args) {
      let responses = tool.input_responses(call)
      process.send(seen, responses)
      case dict.get(responses, "detail") {
        Error(Nil) ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "detail",
                  tool.InputRequest(
                    tool.Elicitation,
                    value.Object([#("message", value.String("More detail?"))]),
                  ),
                ),
              ]),
            ),
          )
        Ok(answer) ->
          Ok(
            tool.complete(
              prompts.PromptResult(
                None,
                [
                  prompts.user_message(
                    tool.context(call)
                    <> result_or(dict.get(args, "topic"), "")
                    <> " "
                    <> value.to_string(answer),
                  ),
                ],
                [],
              ),
            ),
          )
      }
    })
  let assert Ok(peer) =
    client.in_process(server.new([]) |> server.with_prompts([asking]), "ctx:")
    |> client.with_input_methods([tool.Elicitation])
    |> client.connect
  let assert Ok(first) =
    client.call_raw(peer, "prompts/get", Some("asking"), [
      #("name", json.string("asking")),
      #("arguments", json.object([#("topic", json.string("gleam"))])),
    ])
  let assert Ok(dict_first) = process.receive(seen, 100)
  dict.is_empty(dict_first) |> should.be_true
  let assert value.Object(members) = first
  list.key_find(members, "resultType")
  |> should.equal(Ok(value.String("input_required")))
  let assert Ok(value.String(request_state)) =
    list.key_find(members, "requestState")
  let assert Ok(value.Object(requests)) =
    list.key_find(members, "inputRequests")
  let assert Ok(value.Object(detail)) = list.key_find(requests, "detail")
  list.key_find(detail, "method")
  |> should.equal(Ok(value.String("elicitation/create")))

  let assert Ok(second) =
    client.call_raw(peer, "prompts/get", Some("asking"), [
      #("name", json.string("asking")),
      #("arguments", json.object([#("topic", json.string("gleam"))])),
      #("requestState", json.string(request_state)),
      #(
        "inputResponses",
        json.object([
          #("detail", json.object([#("action", json.string("accept"))])),
        ]),
      ),
    ])
  let assert Ok(resumed) = process.receive(seen, 100)
  dict.get(resumed, "detail")
  |> should.equal(Ok(value.Object([#("action", value.String("accept"))])))
  string.contains(
    value.to_string(second),
    "ctx:gleam {\\\"action\\\":\\\"accept\\\"}",
  )
  |> should.be_true

  // A forged request state is refused.
  let assert Error(client.RpcError(-32_602, _, _, ..)) =
    client.call_raw(peer, "prompts/get", Some("asking"), [
      #("name", json.string("asking")),
      #("arguments", json.object([])),
      #("requestState", json.string("forged")),
      #("inputResponses", json.object([#("detail", json.object([]))])),
    ])
  client.close(peer)
}

// --- completion --------------------------------------------------------------

pub fn completion_receives_the_spec_shaped_request_test() {
  let seen = process.new_subject()
  let completer =
    completion.completion(fn(context: String, request: completion.Request) {
      process.send(seen, #(context, request))
      Ok(completion.Values(["a", "b"], Some(10), Some(True)))
    })
  let peer =
    testing.connect(
      server.new([]) |> server.with_completion(completer),
      "tenant",
    )
  let prompt_request =
    completion.Request(
      reference: completion.PromptReference("review"),
      argument: "style",
      value: "st",
      context: dict.from_list([#("code", "x = 1"), #("lang", "gleam")]),
    )
  client.complete(peer, prompt_request)
  |> should.equal(Ok(completion.Values(["a", "b"], Some(10), Some(True))))
  process.receive(seen, 100) |> should.equal(Ok(#("tenant", prompt_request)))

  let resource_request =
    completion.Request(
      reference: completion.ResourceReference("file:///notes/{id}"),
      argument: "id",
      value: "",
      context: dict.new(),
    )
  let assert Ok(_) = client.complete(peer, resource_request)
  process.receive(seen, 100) |> should.equal(Ok(#("tenant", resource_request)))
  client.close(peer)
}

pub fn completion_values_keeps_the_first_hundred_test() {
  let many =
    int.range(from: 1, to: 151, with: [], run: list.prepend)
    |> list.reverse
    |> list.map(int.to_string)
  let kept = completion.values(many)
  kept.values |> should.equal(list.take(many, 100))
  kept.total |> should.equal(None)
  kept.has_more |> should.equal(None)
  completion.values(["x"]) |> should.equal(completion.Values(["x"], None, None))

  // An oversized Values is cut to 100 on the wire too.
  let peer =
    testing.connect(
      server.new([])
        |> server.with_completion(
          completion.completion(fn(_ctx: Nil, _request) {
            Ok(completion.Values(many, Some(150), Some(True)))
          }),
        ),
      Nil,
    )
  let assert Ok(received) =
    client.complete(
      peer,
      completion.Request(completion.PromptReference("p"), "a", "", dict.new()),
    )
  received.values |> should.equal(list.take(many, 100))
  received.total |> should.equal(Some(150))
  received.has_more |> should.equal(Some(True))
  client.close(peer)
}
