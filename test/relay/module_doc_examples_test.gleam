//// The module-doc examples, compiled and run. The usage recipes live in
//// `examples/relay_usage`, a separate package the examples gate builds and runs.

import gleam/dict
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import json/blueprint/codec
import relay/client
import relay/completion
import relay/content
import relay/prompts
import relay/reducer
import relay/resources
import relay/runtime
import relay/server
import relay/subscriptions.{ResourceUpdated, ToolsListChanged}
import relay/telemetry
import relay/testing
import relay/tool
import sinal

fn greet() -> tool.Definition(String, String) {
  let input = {
    use name <- codec.field("name", codec.string(), get: fn(name) { name })
    codec.success(name)
  }
  tool.define("greet", input, codec.string())
  |> tool.with_description("Greets the user by name")
  |> tool.with_read_only_hint(True)
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
