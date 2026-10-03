//// The README and module-doc examples, compiled and, where they need no
//// outside party, run.

import gleam/bytes_tree
import gleam/dict
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun/cancellation
import http_gun/deadline
import json/blueprint/codec
import relay/authorization
import relay/client
import relay/completion
import relay/content
import relay/http
import relay/prompts
import relay/reducer
import relay/resources
import relay/runtime
import relay/server
import relay/stdio
import relay/subscriptions.{ResourceUpdated, ToolsListChanged}
import relay/telemetry
import relay/testing
import relay/tool
import sinal

// --- README: serve a tool and call it ----------------------------------------

fn greet() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
  |> tool.with_description("Greets the user by name")
  |> tool.with_read_only_hint(True)
}

pub fn readme_serve_and_call_test() {
  let service =
    server.new([tool.handle(greet(), fn(name) { Ok("Hello, " <> name <> "!") })])
  let assert Ok(mcp) = http.start(http.new(service))
  let url = "http://127.0.0.1:" <> int.to_string(http.port(mcp)) <> "/"

  let assert Ok(config) = client.http(url)
  let assert Ok(peer) = client.connect(config)
  let assert Ok(client.Succeeded("Hello, Ada!", _)) =
    client.call(peer, greet(), "Ada")
  client.close(peer)
  http.stop(mcp)
}

// --- README: stdio (compiled only: it reads standard input) ------------------

pub fn readme_stdio_main() {
  let assert Ok(Nil) = stdio.serve(server.new([]), Nil)
}

// --- README: mount ------------------------------------------------------------

pub type Tenant {
  Tenant(id: String)
}

fn mount(service: server.Server(Tenant)) -> http.Handler(Tenant) {
  let assert Ok(mcp) =
    http.new_with_context(service, fn(req) {
      case request.get_header(req, "x-tenant") {
        Ok(id) -> Ok(Tenant(id))
        Error(Nil) ->
          Error(response.new(400) |> response.set_body(bytes_tree.new()))
      }
    })
    |> http.with_allowed_hosts(["mcp.example.com", "127.0.0.1"])
    |> http.handler
  mcp
}

pub fn readme_mount_test() {
  let whoami =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let Tenant(id) = tool.context(call)
      Ok(tool.complete(id))
    })
  let mcp = mount(server.new([whoami]))
  let call =
    testing.request("tools/call", [
      #("name", json_string("whoami")),
      #("arguments", json_object([])),
    ])
  let answered = http.handle(mcp, request.set_header(call, "x-tenant", "acme"))
  let assert 200 = answered.status
  let assert True = string.contains(testing.body_text(answered), "acme")
  let assert 400 = http.handle(mcp, call).status
  http.stop(mcp)
}

// --- README: protect ------------------------------------------------------------

pub type Claims {
  Claims(subject: String, audiences: List(String), scopes: List(String))
}

fn protect(
  service: server.Server(Claims),
  validate: fn(String) -> Result(Claims, Nil),
) -> http.Config(Claims) {
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.com/mcp")
  let assert Ok(reports) = authorization.scope("reports")
  let protection =
    authorization.protection(resource, [reports])
    |> authorization.with_authorization_servers(["https://login.example.com"])
  let verifier = {
    use token <- authorization.verifier("jwt")
    validate(authorization.token_value(token))
    |> result.map(fn(c) { authorization.attestation(c, c.audiences, c.scopes) })
    |> result.replace_error(authorization.BearerRejected)
  }
  http.new_protected(service, verifier, protection, fn(_request, grant) {
    Ok(authorization.grant_principal(grant))
  })
}

pub fn readme_protect_test() {
  let claims =
    Claims("ada", ["https://mcp.example.com/mcp"], ["reports", "profile"])
  let validate = fn(token) {
    case token {
      "good" -> Ok(claims)
      _ -> Error(Nil)
    }
  }
  let subject =
    tool.define("subject", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      let claims: Claims = tool.context(call)
      Ok(tool.complete(claims.subject))
    })
  let assert Ok(mcp) =
    protect(server.new([subject]), validate)
    |> http.with_allowed_hosts(["127.0.0.1"])
    |> http.handler
  let call =
    testing.request("tools/call", [
      #("name", json_string("subject")),
      #("arguments", json_object([])),
    ])
  let refused = http.handle(mcp, call)
  let assert 401 = refused.status
  let assert Ok(challenge) = response.get_header(refused, "www-authenticate")
  let assert True = string.contains(challenge, "resource_metadata=")
  let granted =
    http.handle(mcp, request.set_header(call, "authorization", "Bearer good"))
  let assert 200 = granted.status
  let assert True = string.contains(testing.body_text(granted), "ada")
  http.stop(mcp)
}

// --- README: views ----------------------------------------------------------------

fn call_with_budget(
  peer: client.Client,
  definition: tool.Definition(String, String),
) -> Result(client.ToolResult(String), client.Error) {
  use token <- cancellation.with_token
  peer
  |> client.with_deadline(deadline.after(duration.seconds(10)))
  |> client.with_cancellation(token)
  |> client.call(definition, "Ada")
}

pub fn readme_views_test() {
  let peer =
    testing.connect(
      server.new([tool.handle(greet(), fn(name) { Ok("Hi " <> name) })]),
      Nil,
    )
  let assert Ok(client.Succeeded("Hi Ada", _)) = call_with_budget(peer, greet())
  client.close(peer)
}

// --- module docs ------------------------------------------------------------------

fn tool_doc_example() -> tool.Tool(Nil) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
  |> tool.with_description("Greets the user by name")
  |> tool.with_read_only_hint(True)
  |> tool.handle(fn(name) { Ok("Hello, " <> name <> "!") })
}

fn server_doc_example() -> server.Server(Nil) {
  let say_input = {
    use text <- codec.field("text", codec.string(), get: fn(text) { text })
    codec.success(text)
  }
  let say =
    tool.define("say", say_input, codec.string())
    |> tool.handle(fn(text) { Ok(text) })
  let readme =
    resources.static("memo://readme", "Readme", fn(_context, uri) {
      Ok([content.text_resource(uri, "Hello")])
    })
  server.new([say])
  |> server.with_resources([readme])
  |> server.with_info("notes", "1.0.0")
}

fn content_doc_example() -> List(content.ContentBlock) {
  let note =
    content.text("Report ready")
    |> content.with_annotations(
      content.Annotations(..content.empty_annotations(), priority: Some(0.8)),
    )
  [note, content.image(<<137, 80, 78, 71>>, "image/png")]
}

fn resources_doc_example() -> resources.Resource(Nil) {
  resources.static("memo://readme", "Readme", fn(_context, uri) {
    Ok([content.text_resource(uri, "Hello")])
  })
  |> resources.with_mime_type("text/plain")
}

fn prompts_doc_example() -> prompts.Prompt(Nil) {
  prompts.prompt("review", [prompts.required_argument("code")], fn(_, args) {
    use code <- result.map(dict.get(args, "code"))
    prompts.PromptResult(None, [prompts.user_message("Review:\n" <> code)], [])
  })
}

fn completion_doc_example() -> completion.Completion(Nil) {
  completion.completion(fn(_context, request: completion.Request) {
    ["gleam", "erlang", "elixir"]
    |> list.filter(string.starts_with(_, request.value))
    |> completion.values
    |> Ok
  })
}

fn subscriptions_doc_example() -> List(subscriptions.Notification) {
  [ToolsListChanged, ResourceUpdated("file:///notes.txt")]
}

fn reducer_doc_example(bytes: BitArray) -> List(reducer.Effect(Nil)) {
  let state = reducer.init(server.new([]))
  let exchange = reducer.new_exchange_id()
  let #(_state, effects) =
    reducer.step(state, reducer.Received(exchange, Nil, bytes, None))
  effects
}

fn runtime_doc_example(frame: BitArray) {
  let assert Ok(rt) =
    runtime.start(server.new([]), runtime.config(), fn(output) {
      case output {
        runtime.OutputWrite(_exchange, _bytes) -> Ok(Nil)
        runtime.OutputClose(_exchange) -> Ok(Nil)
      }
    })
  let _ = runtime.send_frame(rt, reducer.new_exchange_id(), Nil, frame, None)
  runtime.stop(rt)
}

fn telemetry_doc_example() -> sinal.Attachment {
  use _measured, meta <- sinal.observe(telemetry.invocation_started_event())
  case meta.tool {
    option.Some(name) -> io.println("tool " <> name)
    option.None -> Nil
  }
}

fn testing_doc_example() {
  let input = {
    use text <- codec.field("text", codec.string(), get: fn(text) { text })
    codec.success(text)
  }
  let say = tool.define("say", input, codec.string())
  let peer = testing.connect(server.new([tool.handle(say, Ok)]), Nil)
  let assert Ok(client.Succeeded("hi", _)) = client.call(peer, say, "hi")
  client.close(peer)
}

pub fn module_doc_examples_test() {
  let peer =
    testing.connect(
      server_doc_example()
        |> server.register_tool(tool_doc_example())
        |> result.unwrap(server_doc_example())
        |> server.with_prompts([prompts_doc_example()])
        |> server.with_completion(completion_doc_example())
        |> server.with_resources([resources_doc_example()]),
      Nil,
    )
  let assert Ok(client.Succeeded("Hello, Ada!", _)) =
    client.call(peer, greet(), "Ada")
  let assert Ok(prompt) =
    client.get_prompt(peer, "review", dict.from_list([#("code", "x")]))
  let assert [_] = prompt.messages
  let assert Ok(values) =
    client.complete(
      peer,
      completion.Request(
        completion.PromptReference("review"),
        "code",
        "gl",
        dict.new(),
      ),
    )
  let assert ["gleam"] = values.values
  client.close(peer)
  let assert [_, _] = content_doc_example()
  let assert [_, _] = subscriptions_doc_example()
  let assert [reducer.Write(..), reducer.Close(_)] =
    reducer_doc_example(<<"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"nope\"}">>)
  runtime_doc_example(<<"{}">>)
  let attachment = telemetry_doc_example()
  let _ = sinal.detach(attachment)
  testing_doc_example()
}

fn json_string(text: String) -> json.Json {
  json.string(text)
}

fn json_object(members: List(#(String, json.Json))) -> json.Json {
  json.object(members)
}
