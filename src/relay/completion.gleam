//// Argument completion handlers for prompts and resource templates
//// (`completion/complete`).
////
//// `completion` wraps an application handler and replaces its error with a
//// generic `CompletionFailed`. `completion_with_context` also receives the
//// request's context arguments, when present, and returns `CompletionError`
//// directly. `completion_values` and the JSON encoder keep at most 100 values.
//// Attach a handler with `relay/server.with_completion`; a client calls it with
//// `relay/client.complete`.

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub type CompletionRef {
  PromptRef(name: String)
  ResourceRef(uri_template: String)
}

pub type CompletionArgument {
  CompletionArgument(name: String, value: String)
}

pub type CompletionValues {
  CompletionValues(
    values: List(String),
    total: Option(Int),
    has_more: Option(Bool),
  )
}

pub fn completion_values(values: List(String)) -> CompletionValues {
  CompletionValues(values: list.take(values, 100), total: None, has_more: None)
}

pub type CompletionError {
  CompletionFailed(reason: String)
}

pub type ContextCompletion(context) {
  ContextCompletion(
    complete: fn(
      context,
      CompletionRef,
      CompletionArgument,
      Option(Dict(String, String)),
    ) -> Result(CompletionValues, CompletionError),
  )
}

pub fn completion(
  complete: fn(context, CompletionRef, CompletionArgument) ->
    Result(CompletionValues, application_error),
) -> ContextCompletion(context) {
  ContextCompletion(fn(context, reference, argument, _context) {
    complete(context, reference, argument)
    |> result.map_error(fn(_) { CompletionFailed("Completion handler failed") })
  })
}

pub fn completion_with_context(
  complete: fn(
    context,
    CompletionRef,
    CompletionArgument,
    Option(Dict(String, String)),
  ) -> Result(CompletionValues, CompletionError),
) -> ContextCompletion(context) {
  ContextCompletion(complete)
}

pub fn completion_values_to_json(comp: CompletionValues) -> json.Json {
  let bounded_values = list.take(comp.values, 100)
  let fields = [#("values", json.array(bounded_values, json.string))]
  let fields = case comp.total {
    None -> fields
    Some(t) -> list.append(fields, [#("total", json.int(t))])
  }
  let fields = case comp.has_more {
    None -> fields
    Some(h) -> list.append(fields, [#("hasMore", json.bool(h))])
  }
  json.object(fields)
}
