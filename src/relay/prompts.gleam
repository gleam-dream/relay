import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/value.{type Value}
import relay/content.{
  type ContentBlock, type Role, content_block_to_json, role_to_string,
}
import relay/tool.{type InputRequest}

pub type PromptArgument {
  PromptArgument(
    name: String,
    description: Option(String),
    required: Bool,
    title: Option(String),
  )
}

pub fn prompt_argument(name: String, required: Bool) -> PromptArgument {
  PromptArgument(name: name, description: None, required: required, title: None)
}

pub type Prompt {
  Prompt(
    name: String,
    title: Option(String),
    description: Option(String),
    arguments: List(PromptArgument),
  )
}

pub type PromptMessage {
  PromptMessage(role: Role, content: ContentBlock)
}

pub type PromptResult {
  PromptResult(description: Option(String), messages: List(PromptMessage))
}

pub type PromptHandlerResult {
  CompletePrompt(PromptResult)
  RequestPromptInput(Dict(String, InputRequest))
}

pub type PromptError {
  PromptNotFound(name: String)
  PromptInvalidArguments(reason: String)
  PromptFailed(reason: String)
}

pub type ContextPrompt(context) {
  ContextPrompt(
    prompt: Prompt,
    get: fn(context, Dict(String, String)) -> Result(PromptResult, PromptError),
  )
  ContextPromptWithInputs(
    prompt: Prompt,
    get: fn(context, Dict(String, String), Option(Value)) ->
      Result(PromptHandlerResult, PromptError),
  )
}

pub fn prompt(
  name: String,
  arguments: List(PromptArgument),
  get: fn(context, Dict(String, String)) ->
    Result(PromptResult, application_error),
) -> ContextPrompt(context) {
  ContextPrompt(
    prompt: Prompt(
      name: name,
      title: None,
      description: None,
      arguments: arguments,
    ),
    get: fn(context, arguments) {
      get(context, arguments)
      |> result.map_error(fn(_) { PromptFailed("Prompt handler failed") })
    },
  )
}

pub fn prompt_with_inputs(
  prompt: Prompt,
  get: fn(context, Dict(String, String), Option(Value)) ->
    Result(PromptHandlerResult, PromptError),
) -> ContextPrompt(context) {
  ContextPromptWithInputs(prompt, get)
}

pub fn prompt_argument_to_json(arg: PromptArgument) -> json.Json {
  let fields = [
    #("name", json.string(arg.name)),
    #("required", json.bool(arg.required)),
  ]
  let fields = case arg.title {
    None -> fields
    Some(t) -> list.append(fields, [#("title", json.string(t))])
  }
  let fields = case arg.description {
    None -> fields
    Some(d) -> list.append(fields, [#("description", json.string(d))])
  }
  json.object(fields)
}

pub fn prompt_to_json(p: Prompt) -> json.Json {
  let fields = [
    #("name", json.string(p.name)),
    #("arguments", json.array(p.arguments, prompt_argument_to_json)),
  ]
  let fields = case p.title {
    None -> fields
    Some(t) -> list.append(fields, [#("title", json.string(t))])
  }
  let fields = case p.description {
    None -> fields
    Some(d) -> list.append(fields, [#("description", json.string(d))])
  }
  json.object(fields)
}

pub fn prompt_message_to_json(msg: PromptMessage) -> json.Json {
  json.object([
    #("role", json.string(role_to_string(msg.role))),
    #("content", content_block_to_json(msg.content)),
  ])
}
