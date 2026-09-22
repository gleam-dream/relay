import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import json/blueprint/codec
import relay/runtime.{RuntimeConfig}
import relay/server
import relay/tool
import relay/transport/stdio

@external(erlang, "erlang", "halt")
fn ffi_halt(status: Int) -> Nil

pub fn main() -> Nil {
  let assert Ok(greet_name) = tool.tool_name("greet")
  let assert Ok(greet_tool) = case
    tool.definition(
      greet_name,
      codec.field("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Greets user"),
          ),
        )
      Ok({
        let user_handler = fn(ctx: String, user: String) {
          Ok(ctx <> ": hello " <> user)
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          fn(call, typed_input) {
            let tool.HandlerCallContext(
              application,
              _input_responses,
              _report_progress,
            ) = call
            case user_handler(application, typed_input) {
              Ok(output) -> Ok(tool.Complete(output, []))
            }
          },
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }

  let assert Ok(fail_name) = tool.tool_name("fail_tool")
  let assert Ok(fail_tool) = case
    tool.definition(
      fail_name,
      codec.field("msg", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Fails with tool error"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(msg: String) { Error("application error: " <> msg) },
          fn(application_error) {
            case
              codec.encode_json(
                codec.field("reason", codec.string()),
                application_error,
              )
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(slow_name) = tool.tool_name("slow")
  let assert Ok(slow_tool) = case
    tool.definition(slow_name, codec.field("ms", codec.int()), codec.string())
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Delays its response"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(delay_ms: Int) {
            process.sleep(delay_ms)
            Ok("slow response")
          },
          fn(application_error) {
            case
              codec.encode_json(codec.object(codec.empty()), application_error)
            {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(reg) = tool.registry([greet_tool, fail_tool, slow_tool])
  let s = server.server(reg)
  let runtime_config =
    RuntimeConfig(
      max_live_exchanges: 100,
      max_frame_bytes: 1024,
      invocation_timeout_ms: 30_000,
      tombstone_retention_ms: 60_000,
    )
  let config =
    stdio.LocalUnprotectedStdioConfig(
      chunk_size: 1,
      runtime_config: runtime_config,
    )

  // Diagnostic written to isolated stderr
  stdio.log_stderr("Child stdio server starting")

  case stdio.run_local_unprotected_stdio_server(s, config, "child-server") {
    Ok(Nil) -> ffi_halt(0)
    Error(err) -> {
      stdio.log_stderr("Child server failed: " <> string.inspect(err))
      ffi_halt(1)
    }
  }
  Nil
}
