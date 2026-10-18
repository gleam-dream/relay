//// Compose typed tool calls. `relay/client/output` is an optional convenience
//// boundary for non-interactive callers that need the native answer: it folds
//// the success, tool-failure and input-required results and the client error
//// into one `Result`. Keep the original `client.ToolResult` when you need
//// input continuations or media content.
////
//// Run: `gleam run -m relay_usage/typed_output`

import gleam/io
import json/blueprint/codec
import relay/client
import relay/client/output
import relay/server
import relay/testing
import relay/tool

fn double() -> tool.Definition(Int, Int) {
  let input = {
    use n <- codec.field("n", codec.int(), get: fn(n) { n })
    codec.success(n)
  }
  tool.define("double", input, codec.int())
}

pub fn run() -> Nil {
  let service =
    server.new([
      tool.handle(double(), fn(n) {
        case n < 0 {
          True -> Error("negative")
          False -> Ok(n * 2)
        }
      }),
    ])
  let peer = testing.connect(service, Nil)

  // The native answer, with no result variants to unwrap.
  let assert Ok(8) = client.call(peer, double(), 4) |> output.require

  // A tool refusal and a transport failure stay distinguishable, and the
  // evidence records whether the request may have run.
  let assert Error(refusal) = client.call(peer, double(), -1) |> output.require
  let assert output.ToolRefusal = output.error_kind(refusal)
  let assert client.Completed = output.evidence(refusal)
  let assert "Tool execution failed." = output.describe_error(refusal)
  client.close(peer)
}

pub fn main() -> Nil {
  run()
  io.println("typed_output: ok")
}
