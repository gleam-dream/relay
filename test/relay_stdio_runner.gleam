import gleam/erlang/process
import gleam/string
import json/blueprint/codec
import relay
import relay/runtime.{RuntimeConfig}
import relay/server
import relay/transport/stdio

@external(erlang, "erlang", "halt")
fn ffi_halt(status: Int) -> Nil

pub fn main() -> Nil {
  let assert Ok(greet_name) = relay.tool_name("greet")
  let assert Ok(greet_tool) =
    relay.context_tool(
      greet_name,
      relay.tool_metadata("Greets user"),
      codec.field("name", codec.string()),
      codec.string(),
      codec.object(codec.empty()),
      fn(ctx: String, user: String) { Ok(ctx <> ": hello " <> user) },
    )

  let assert Ok(fail_name) = relay.tool_name("fail_tool")
  let assert Ok(fail_tool) =
    relay.context_tool(
      fail_name,
      relay.tool_metadata("Fails with tool error"),
      codec.field("msg", codec.string()),
      codec.string(),
      codec.field("reason", codec.string()),
      fn(_ctx: String, msg: String) { Error("application error: " <> msg) },
    )

  let assert Ok(slow_name) = relay.tool_name("slow")
  let assert Ok(slow_tool) =
    relay.context_tool(
      slow_name,
      relay.tool_metadata("Delays its response"),
      codec.field("ms", codec.int()),
      codec.string(),
      codec.object(codec.empty()),
      fn(_ctx: String, delay_ms: Int) {
        process.sleep(delay_ms)
        Ok("slow response")
      },
    )

  let assert Ok(reg) = relay.registry([greet_tool, fail_tool, slow_tool])
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
