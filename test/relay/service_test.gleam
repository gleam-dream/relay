import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import relay
import relay/completion
import relay/content
import relay/prompts
import relay/resources
import relay/server
import relay/subscriptions

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_server() -> server.Server(String) {
  let assert Ok(registry) = relay.registry([])
  let resource =
    resources.resource("memory://notes/1", "note", fn(_context, uri) {
      Ok([content.TextResourceContents(uri, "the note", Some("text/plain"))])
    })
  let template =
    resources.resource_template(
      "memory://notes/{id}",
      "note by id",
      fn(_context, uri) {
        Ok([content.TextResourceContents(uri, "templated note", None)])
      },
    )
  let prompt =
    prompts.prompt("welcome", [], fn(_context, _arguments) {
      Ok(
        prompts.PromptResult(None, [
          prompts.PromptMessage(content.UserRole, content.text_content("hello")),
        ]),
      )
    })
  let completion =
    completion.completion(fn(_context, _reference, argument) {
      Ok(completion.CompletionValues(
        [argument.value, argument.value <> "-next"],
        Some(2),
        Some(False),
      ))
    })
  server.server_with_services(
    registry,
    [resource],
    [template],
    [prompt],
    Some(completion),
  )
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

pub fn modern_catalog_lists_test() {
  let s = sample_server()
  let ex = server.fresh_exchange()
  let #(s1, effects) =
    server.step(
      s,
      server.MessageReceived(ex, "tenant", wire_request("resources/list", [])),
    )
  case effects {
    [
      server.EmitRequestAdmitted(_, "resources/list"),
      server.Write(_, bytes),
      server.CloseExchange(_),
    ] -> {
      let text = response_text(bytes)
      should.be_true(string.contains(text, "memory://notes/1"))
      should.be_true(string.contains(text, "\"name\":\"note\""))
    }
    _ -> should.fail()
  }

  let ex = server.fresh_exchange()
  let #(_s2, effects) =
    server.step(
      s1,
      server.MessageReceived(
        ex,
        "tenant",
        wire_request("resources/templates/list", []),
      ),
    )
  case effects {
    [
      server.EmitRequestAdmitted(_, "resources/templates/list"),
      server.Write(_, bytes),
      server.CloseExchange(_),
    ] ->
      should.be_true(string.contains(
        response_text(bytes),
        "memory://notes/{id}",
      ))
    _ -> should.fail()
  }
}

fn invoke_and_get_response(
  s: server.Server(String),
  method: String,
  fields: List(#(String, json.Json)),
) -> #(server.Server(String), String) {
  let ex = server.fresh_exchange()
  let #(s1, effects) =
    server.step(
      s,
      server.MessageReceived(ex, "tenant", wire_request(method, fields)),
    )
  let assert [
    server.EmitRequestAdmitted(_, admitted_method),
    server.StartInvocation(inv),
  ] = effects
  admitted_method |> should.equal(method)
  let #(s2, effects) = server.step(s1, server.perform(inv))
  let assert [server.Write(_, bytes), server.CloseExchange(_)] = effects
  #(s2, response_text(bytes))
}

pub fn resources_prompts_completion_invocations_test() {
  let s = sample_server()
  let #(s, read_response) =
    invoke_and_get_response(s, "resources/read", [
      #("uri", json.string("memory://notes/1")),
    ])
  should.be_true(string.contains(read_response, "the note"))
  should.be_true(string.contains(read_response, "text/plain"))

  let #(s, prompt_response) =
    invoke_and_get_response(s, "prompts/get", [
      #("name", json.string("welcome")),
      #("arguments", json.object([])),
    ])
  should.be_true(string.contains(prompt_response, "hello"))

  let #(s, completion_response) =
    invoke_and_get_response(s, "completion/complete", [
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
      #("context", json.object([#("audience", json.string("team"))])),
    ])
  should.be_true(string.contains(completion_response, "greeting-next"))
  should.be_true(string.contains(completion_response, "\"total\":2"))
  let _ = s
}

pub fn template_resource_read_test() {
  let s = sample_server()
  let #(_s1, response) =
    invoke_and_get_response(s, "resources/read", [
      #("uri", json.string("memory://notes/42")),
    ])
  should.be_true(string.contains(response, "templated note"))
}

pub fn discovery_advertises_only_delivered_capabilities_test() {
  let #(s, effects) =
    server.step(
      sample_server(),
      server.MessageReceived(
        server.fresh_exchange(),
        "tenant",
        wire_request("server/discover", []),
      ),
    )
  let assert [_, server.Write(_, bytes), _] = effects
  let assert Ok(parsed) = json.parse(response_text(bytes), decode.dynamic)
  let assert Ok(capabilities) =
    decode.run(
      parsed,
      decode.at(
        ["result", "capabilities"],
        decode.dict(decode.string, decode.dynamic),
      ),
    )
  dict.get(capabilities, "completions") |> is_ok |> should.be_true
  dict.get(capabilities, "logging") |> should.be_error()
  let _ = s
}

fn is_ok(value: Result(a, b)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn resource_subscription_registry_is_idempotent_and_owner_scoped_test() {
  let assert Ok(uri) = resources.resource_uri("memory://notes/42")
  let store = subscriptions.new()
  let store = subscriptions.subscribe(store, "client-a", uri)
  let store = subscriptions.subscribe(store, "client-a", uri)
  let store = subscriptions.subscribe(store, "client-b", uri)
  subscriptions.count(store) |> should.equal(2)
  subscriptions.owners_for_resource(store, uri)
  |> list.contains("client-a")
  |> should.be_true

  let store = subscriptions.unsubscribe(store, "client-a", uri)
  subscriptions.is_subscribed(store, "client-a", uri) |> should.be_false
  subscriptions.is_subscribed(store, "client-b", uri) |> should.be_true
  let store = subscriptions.close_owner(store, "client-b")
  subscriptions.count(store) |> should.equal(0)
}

fn many_resources(count: Int) -> List(resources.ContextResource(String)) {
  case count <= 0 {
    True -> []
    False -> [
      resources.resource(
        "memory://items/" <> int.to_string(count),
        "item-" <> int.to_string(count),
        fn(_context, uri) {
          Ok([content.TextResourceContents(uri, "body", None)])
        },
      ),
      ..many_resources(count - 1)
    ]
  }
}

pub fn pagination_cursor_is_opaque_and_family_scoped_test() {
  let assert Ok(registry) = relay.registry([])
  let s =
    server.server_with_services(registry, many_resources(101), [], [], None)
  let ex = server.fresh_exchange()
  let #(s1, effects) =
    server.step(
      s,
      server.MessageReceived(ex, "tenant", wire_request("resources/list", [])),
    )
  let assert [_, server.Write(_, bytes), _] = effects
  let text = response_text(bytes)
  should.be_true(string.contains(text, "\"nextCursor\""))
  let assert Ok(dynamic) = json.parse(text, decode.dynamic)
  let assert Ok(cursor) =
    decode.run(dynamic, decode.at(["result", "nextCursor"], decode.string))

  let ex = server.fresh_exchange()
  let #(s2, effects) =
    server.step(
      s1,
      server.MessageReceived(
        ex,
        "tenant",
        wire_request("resources/list", [#("cursor", json.string(cursor))]),
      ),
    )
  let assert [_, server.Write(_, bytes), _] = effects
  should.be_true(string.contains(response_text(bytes), "memory://items/1"))
  let _ = s2

  let ex = server.fresh_exchange()
  let #(_, effects) =
    server.step(
      s1,
      server.MessageReceived(
        ex,
        "tenant",
        wire_request("prompts/list", [#("cursor", json.string(cursor))]),
      ),
    )
  let assert [server.Write(_, bytes), server.CloseExchange(_)] = effects
  should.be_true(string.contains(response_text(bytes), "-32602"))
}
