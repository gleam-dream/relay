//// Prompts a server lists and renders, for `prompts/list` and
//// `prompts/get`.
////
//// `prompt(name, arguments, get)` declares a prompt; its handler receives
//// the context and the string arguments and returns a `PromptResult`.
//// `prompt_call` mirrors `relay/tool.handle_call`: the handler receives the
//// `relay/tool.Call` and may return `tool.request_input(..)` to ask the
//// client for another input round. A handler's error is hidden from the
//// client, which sees the JSON-RPC invalid-params error.
////
//// Attach prompts with `relay/server.with_prompts`; a client lists them as
//// `Declaration` values and renders one with `relay/client.get_prompt`.
////
//// ```gleam
//// import gleam/dict
//// import gleam/option.{None}
//// import gleam/result
//// import relay/content
//// import relay/prompts
////
//// pub fn review() -> prompts.Prompt(Nil) {
////   prompts.prompt("review", [prompts.required_argument("code")], fn(_, args) {
////     use code <- result.map(dict.get(args, "code"))
////     prompts.PromptResult(None, [prompts.user_message("Review:\n" <> code)], [])
////   })
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import relay/content.{type ContentBlock, type Icon, type Meta, type Role}
import relay/internal/core
import relay/internal/wire
import relay/tool

/// A prompt bound to its handler.
pub type Prompt(context) =
  core.Prompt(context)

/// One argument a prompt accepts.
pub type PromptArgument {
  PromptArgument(
    name: String,
    title: Option(String),
    description: Option(String),
    required: Bool,
  )
}

/// An optional argument with only its name.
pub fn argument(name: String) -> PromptArgument {
  PromptArgument(name: name, title: None, description: None, required: False)
}

/// A required argument with only its name.
pub fn required_argument(name: String) -> PromptArgument {
  PromptArgument(name: name, title: None, description: None, required: True)
}

/// One message of a rendered prompt.
pub type PromptMessage {
  PromptMessage(role: Role, content: ContentBlock)
}

/// A user message with one text block.
pub fn user_message(text: String) -> PromptMessage {
  PromptMessage(content.UserRole, content.text(text))
}

/// An assistant message with one text block.
pub fn assistant_message(text: String) -> PromptMessage {
  PromptMessage(content.AssistantRole, content.text(text))
}

/// A rendered prompt: the `GetPromptResult` of the pinned revision.
pub type PromptResult {
  PromptResult(
    description: Option(String),
    messages: List(PromptMessage),
    meta: Meta,
  )
}

/// A prompt whose handler renders it from the context and its arguments.
pub fn prompt(
  name: String,
  arguments: List(PromptArgument),
  get: fn(context, Dict(String, String)) -> Result(PromptResult, error),
) -> Prompt(context) {
  prompt_call(name, arguments, fn(call, args) {
    get(tool.context(call), args) |> result.map(tool.complete)
  })
}

/// A prompt whose handler receives the `relay/tool.Call` and may request
/// another input round with `tool.request_input`.
pub fn prompt_call(
  name: String,
  arguments: List(PromptArgument),
  get: fn(tool.Call(context), Dict(String, String)) ->
    Result(tool.Reply(PromptResult), error),
) -> Prompt(context) {
  core.Prompt(
    name: name,
    title: None,
    description: None,
    arguments: list.map(arguments, fn(argument) {
      core.PromptArgument(
        argument.name,
        argument.title,
        argument.description,
        argument.required,
      )
    }),
    icons: [],
    meta: [],
    get: fn(call, args) {
      case get(call, args) {
        Error(_) -> Error(Nil)
        Ok(core.NeedsInput(requests)) -> Ok(core.NeedsInput(requests))
        Ok(core.Complete(rendered, blocks)) ->
          Ok(core.Complete(encode_result(rendered), blocks))
      }
    },
  )
}

fn encode_result(rendered: PromptResult) -> core.Encoded {
  core.Encoded(
    fields: list.flatten([
      wire.optional_string("description", rendered.description),
      [
        #(
          "messages",
          json.array(rendered.messages, fn(message) {
            json.object([
              #("role", json.string(wire.role_name(message.role))),
              #("content", wire.content_block_to_json(message.content)),
            ])
          }),
        ),
      ],
    ]),
    meta: rendered.meta,
  )
}

/// Sets the human-readable title.
pub fn with_title(prompt: Prompt(context), title: String) -> Prompt(context) {
  core.Prompt(..prompt, title: Some(title))
}

/// Sets the description.
pub fn with_description(
  prompt: Prompt(context),
  description: String,
) -> Prompt(context) {
  core.Prompt(..prompt, description: Some(description))
}

/// Replaces the icons.
pub fn with_icons(
  prompt: Prompt(context),
  icons: List(Icon),
) -> Prompt(context) {
  core.Prompt(..prompt, icons: icons)
}

/// Replaces the declaration's `_meta` members.
pub fn with_meta(prompt: Prompt(context), meta: Meta) -> Prompt(context) {
  core.Prompt(..prompt, meta: meta)
}

/// A prompt as `prompts/list` publishes it. Read fields by label.
pub type Declaration {
  Declaration(
    name: String,
    title: Option(String),
    description: Option(String),
    arguments: List(PromptArgument),
    icons: List(Icon),
    meta: Meta,
  )
}
