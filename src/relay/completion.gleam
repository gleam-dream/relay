//// Argument completion for prompts and resource templates
//// (`completion/complete`).
////
//// `completion(handler)` binds one handler for the server; it receives the
//// context and a `Request` naming the prompt or template, the argument being
//// completed, its partial value and the values of the other arguments. A
//// handler's error is hidden from the client, which sees the JSON-RPC
//// internal error. Attach it with `relay/server.with_completion`; a client
//// asks with `relay/client.complete`.
////
//// ```gleam
//// import gleam/list
//// import gleam/string
//// import relay/completion
////
//// pub fn languages() -> completion.Completion(Nil) {
////   completion.completion(fn(_context, request: completion.Request) {
////     ["gleam", "erlang", "elixir"]
////     |> list.filter(string.starts_with(_, request.value))
////     |> completion.values
////     |> Ok
////   })
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import relay/internal/core

/// A completion handler.
pub type Completion(context) =
  core.Completion(context)

/// What is being completed: a prompt's argument or a resource template's
/// variable.
pub type Reference {
  PromptReference(name: String)
  ResourceReference(uri_template: String)
}

/// One `completion/complete` request. `context` holds the values of the
/// other arguments the client already knows. Read fields by label.
pub type Request {
  Request(
    reference: Reference,
    argument: String,
    value: String,
    context: Dict(String, String),
  )
}

/// Completion values. The wire carries at most 100; `total` and `has_more`
/// tell the client about the rest.
pub type Values {
  Values(values: List(String), total: Option(Int), has_more: Option(Bool))
}

/// The first 100 values, with no total.
pub fn values(values: List(String)) -> Values {
  Values(values: list.take(values, 100), total: None, has_more: None)
}

/// A completion handler. An `Error` reaches the client as the JSON-RPC
/// internal error.
pub fn completion(
  complete: fn(context, Request) -> Result(Values, error),
) -> Completion(context) {
  core.Completion(fn(context, query) {
    let core.CompletionQuery(target, argument, partial, known) = query
    let reference = case target {
      core.PromptTarget(name) -> PromptReference(name)
      core.ResourceTarget(uri_template) -> ResourceReference(uri_template)
    }
    case complete(context, Request(reference, argument, partial, known)) {
      Error(_) -> Error(Nil)
      Ok(values) -> Ok(encode(values))
    }
  })
}

fn encode(values: Values) -> json.Json {
  let total = case values.total {
    None -> []
    Some(total) -> [#("total", json.int(total))]
  }
  let has_more = case values.has_more {
    None -> []
    Some(has_more) -> [#("hasMore", json.bool(has_more))]
  }
  json.object(
    list.flatten([
      [#("values", json.array(list.take(values.values, 100), json.string))],
      total,
      has_more,
    ]),
  )
}
