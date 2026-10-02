import gleam/bit_array
import gleam/dict
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import json/blueprint/codec
import relay/runtime.{RuntimeConfig}
import relay/server
import relay/telemetry
import relay/test_codec
import relay/tool
import sinal

type ProgressBurstNotice {
  ProgressBurstFinished
}

type SinkGateMessage {
  DecideToHold(process.Subject(Bool))
  StopSinkGate(process.Subject(Nil))
}

@external(erlang, "erlang", "self")
fn ffi_self() -> dynamic.Dynamic

@external(erlang, "relay_ffi", "mailbox_size")
fn ffi_mailbox_size(pid: dynamic.Dynamic) -> Int

pub fn main() -> Nil {
  gleeunit.main()
}

fn send_output_to(
  subject: process.Subject(BitArray),
  output: runtime.RuntimeOutput,
) -> Result(Nil, Nil) {
  case output {
    runtime.OutputWrite(_, bytes) -> process.send(subject, bytes)
    runtime.OutputClose(_) -> Nil
  }
  Ok(Nil)
}

pub fn invalid_runtime_config_reports_field_before_start_test() {
  let config = RuntimeConfig(..runtime.default_config(), max_frame_bytes: 0)
  runtime.validate_config(config)
  |> should.equal(
    Error(runtime.InvalidRuntimeSetting(runtime.MaxFrameBytes, 0)),
  )
  runtime.start(sample_server(), config, fn(_output) { Ok(Nil) })
  |> should.equal(
    Error(
      runtime.InvalidRuntimeConfig(runtime.InvalidRuntimeSetting(
        runtime.MaxFrameBytes,
        0,
      )),
    ),
  )
}

pub fn closing_one_runtime_exchange_preserves_other_exchange_test() {
  let outputs = process.new_subject()
  let assert Ok(rt) =
    runtime.start(sample_server(), runtime.default_config(), fn(output) {
      process.send(outputs, output)
      Ok(Nil)
    })
  let closing = server.fresh_exchange()
  let survivor = server.fresh_exchange()
  let slow =
    make_call_frame("slow-close", "slow", json.object([#("ms", json.int(500))]))
  let greet =
    make_call_frame(
      "survivor",
      "greet",
      json.object([#("name", json.string("Other"))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, closing, "ctx", slow, 1000)
  runtime.exchange_closed(rt, closing)
  let assert Ok(Nil) = runtime.send_frame(rt, survivor, "ctx", greet, 1000)

  let assert Ok(runtime.OutputClose(closed)) = process.receive(outputs, 1000)
  closed |> should.equal(closing)
  let assert Ok(runtime.OutputWrite(written, bytes)) =
    process.receive(outputs, 1000)
  written |> should.equal(survivor)
  let assert Ok(text) = bit_array.to_string(bytes)
  string.contains(text, "Other") |> should.be_true
  let assert Ok(runtime.OutputClose(completed)) = process.receive(outputs, 1000)
  completed |> should.equal(survivor)
  runtime.stop(rt, 1000)
}

pub fn failed_output_closes_only_its_exchange_test() {
  let failed = server.fresh_exchange()
  let survivor = server.fresh_exchange()
  let outputs = process.new_subject()
  let assert Ok(rt) =
    runtime.start(sample_server(), runtime.default_config(), fn(output) {
      case output {
        runtime.OutputWrite(exchange, _) if exchange == failed -> Error(Nil)
        _ -> {
          process.send(outputs, output)
          Ok(Nil)
        }
      }
    })
  let assert Ok(Nil) =
    runtime.send_frame(rt, failed, "ctx", make_discover_frame("failed"), 1000)
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      survivor,
      "ctx",
      make_discover_frame("survivor"),
      1000,
    )
  let assert Ok(runtime.OutputClose(closed)) = process.receive(outputs, 1000)
  closed |> should.equal(failed)
  let assert Ok(runtime.OutputWrite(written, _)) =
    process.receive(outputs, 1000)
  written |> should.equal(survivor)
  let assert Ok(runtime.OutputClose(completed)) = process.receive(outputs, 1000)
  completed |> should.equal(survivor)
  runtime.stop(rt, 1000)
}

fn sample_server() -> server.Server(String) {
  let assert Ok(greet_name) = tool.tool_name("greet")
  let assert Ok(greet_tool) = case
    tool.definition(
      greet_name,
      test_codec.property("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Greets a user"),
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
            case codec.encode_json(codec.success(Nil), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }

  let assert Ok(crash_name) = tool.tool_name("crash")
  let assert Ok(crash_tool) = case
    tool.definition(
      crash_name,
      test_codec.property("name", codec.string()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Always crashes"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(_user: String) {
            panic as "Deliberate handler crash: secret-token-7B3F"
          },
          fn(application_error) {
            case codec.encode_json(codec.success(Nil), application_error) {
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
    tool.definition(
      slow_name,
      test_codec.property("ms", codec.int()),
      codec.string(),
    )
  {
    Ok(definition) -> {
      let definition =
        tool.with_metadata(
          definition,
          tool.ToolMetadata(
            ..tool.empty_metadata(),
            description: Some("Slow handler"),
          ),
        )
      Ok(
        tool.handle_with_error_renderer(
          definition,
          fn(ms: Int) {
            process.sleep(ms)
            Ok("finished slow")
          },
          fn(application_error) {
            case codec.encode_json(codec.success(Nil), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        ),
      )
    }
    Error(error) -> Error(error)
  }

  let assert Ok(reg) = tool.registry([greet_tool, crash_tool, slow_tool])
  server.server(reg)
}

fn make_discover_frame(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("server/discover")),
    #(
      "params",
      json.object([
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn make_call_frame(id: String, tool_name: String, args: json.Json) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
          ]),
        ),
        #("name", json.string(tool_name)),
        #("arguments", args),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

pub fn runtime_lifecycle_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  // 1. Discover
  let ex1 = server.fresh_exchange()
  let assert Ok(Nil) =
    runtime.send_frame(rt, ex1, "test_ctx", make_discover_frame("disc-1"), 1000)

  let assert Ok(out1) = process.receive(sink_subj, 1000)
  let assert Ok(str1) = bit_array.to_string(out1)
  let assert Ok(json1) = json.parse(str1, decode.dynamic)
  let assert Ok(dict1) =
    decode.run(json1, decode.dict(decode.string, decode.dynamic))
  let assert Ok(_) = dict.get(dict1, "result")

  // 2. Tools call
  let ex2 = server.fresh_exchange()
  let call_frame =
    make_call_frame(
      "call-1",
      "greet",
      json.object([#("name", json.string("Alice"))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "my_ctx", call_frame, 1000)

  let assert Ok(out2) = process.receive(sink_subj, 1000)
  let assert Ok(str2) = bit_array.to_string(out2)
  let assert Ok(json2) = json.parse(str2, decode.dynamic)
  let assert Ok(dict2) =
    decode.run(json2, decode.dict(decode.string, decode.dynamic))
  let assert Ok(res2_dyn) = dict.get(dict2, "result")
  let assert Ok(res2_dict) =
    decode.run(res2_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(struct_content) = dict.get(res2_dict, "structuredContent")
  let assert Ok(content_str) = decode.run(struct_content, decode.string)
  content_str |> should.equal("my_ctx: hello Alice")

  runtime.stop(rt, 1000)
}

pub fn duplicate_exchange_does_not_consume_live_capacity_test() {
  let config = RuntimeConfig(..runtime.default_config(), max_live_exchanges: 1)
  let output = process.new_subject()
  let assert Ok(rt) =
    runtime.start(sample_server(), config, fn(item) {
      send_output_to(output, item)
    })
  let duplicate = server.fresh_exchange()
  let request = make_discover_frame("duplicate")

  let assert Ok(Nil) = runtime.send_frame(rt, duplicate, "ctx", request, 1000)
  let assert Ok(_) = process.receive(output, 1000)
  let assert Ok(Nil) = runtime.send_frame(rt, duplicate, "ctx", request, 1000)
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      server.fresh_exchange(),
      "ctx",
      make_discover_frame("fresh"),
      1000,
    )

  runtime.stop(rt, 1000)
}

pub fn runtime_crash_isolation_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let crash_subj = process.new_subject()
  let crash_event = telemetry.invocation_crashed_event()
  let crash_handler = fn(_meas, meta: telemetry.InvocationCrashedMeta) {
    process.send(crash_subj, meta)
  }
  let crash_attachment = sinal.observe(crash_event, crash_handler)
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  // Call the crashing tool
  let ex = server.fresh_exchange()
  let call_crash =
    make_call_frame(
      "crash-1",
      "crash",
      json.object([#("name", json.string("test"))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex, "ctx", call_crash, 1000)

  // Expect sanitized internal error (-32603)
  let assert Ok(out) = process.receive(sink_subj, 1000)
  let assert Ok(str) = bit_array.to_string(out)
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(d) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(err_dyn) = dict.get(d, "error")
  let assert Ok(err_dict) =
    decode.run(err_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(code_dyn) = dict.get(err_dict, "code")
  let assert Ok(code) = decode.run(code_dyn, decode.int)
  code |> should.equal(-32_603)
  let assert Ok(crash_meta) = process.receive(crash_subj, 1000)
  crash_meta.reason |> should.equal("handler crashed (redacted)")
  string.contains(crash_meta.reason, "secret-token-7B3F")
  |> should.equal(False)

  // Verify owner is still alive and responds to normal requests
  let ex_alive = server.fresh_exchange()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      ex_alive,
      "ctx",
      make_discover_frame("alive-1"),
      1000,
    )
  let assert Ok(out_alive) = process.receive(sink_subj, 1000)
  let assert Ok(str_alive) = bit_array.to_string(out_alive)
  let assert Ok(parsed_alive) = json.parse(str_alive, decode.dynamic)
  let assert Ok(dict_alive) =
    decode.run(parsed_alive, decode.dict(decode.string, decode.dynamic))
  let assert Ok(_) = dict.get(dict_alive, "result")

  runtime.stop(rt, 1000)
  let assert Ok(Nil) = sinal.detach(crash_attachment)
}

pub fn request_admitted_runtime_observation_test() {
  let event_subj = process.new_subject()
  let ev = telemetry.request_admitted_event()
  let handler = fn(_meas, meta: telemetry.RequestAdmittedMeta) {
    process.send(event_subj, meta)
  }
  let att = sinal.observe(ev, handler)
  let assert Ok(rt) =
    runtime.start(sample_server(), runtime.default_config(), fn(_output) {
      Ok(Nil)
    })
  let exchange = server.fresh_exchange()

  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      exchange,
      "ctx",
      make_discover_frame("admitted"),
      1000,
    )
  let assert Ok(meta) = process.receive(event_subj, 1000)
  meta.exchange_id |> should.equal(server.exchange_id_to_int(exchange))
  meta.method |> should.equal("server/discover")

  runtime.stop(rt, 1000)
  let assert Ok(Nil) = sinal.detach(att)
}

pub fn runtime_timeout_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  // Short timeout: 50ms
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 1024,
      invocation_timeout_ms: 50,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  // Call slow tool for 300ms
  let ex = server.fresh_exchange()
  let call_slow =
    make_call_frame("slow-1", "slow", json.object([#("ms", json.int(300))]))
  let assert Ok(Nil) = runtime.send_frame(rt, ex, "ctx", call_slow, 1000)

  // Expect internal error (-32603) from timeout
  let assert Ok(out) = process.receive(sink_subj, 1000)
  let assert Ok(str) = bit_array.to_string(out)
  let assert Ok(parsed) = json.parse(str, decode.dynamic)
  let assert Ok(d) =
    decode.run(parsed, decode.dict(decode.string, decode.dynamic))
  let assert Ok(err_dyn) = dict.get(d, "error")
  let assert Ok(err_dict) =
    decode.run(err_dyn, decode.dict(decode.string, decode.dynamic))
  let assert Ok(code_dyn) = dict.get(err_dict, "code")
  let assert Ok(code) = decode.run(code_dyn, decode.int)
  code |> should.equal(-32_603)

  runtime.stop(rt, 1000)
}

pub fn runtime_cancellation_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 1024,
      invocation_timeout_ms: 5000,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  // Start slow tool
  let ex1 = server.fresh_exchange()
  let call_slow =
    make_call_frame(
      "cancel-req-1",
      "slow",
      json.object([#("ms", json.int(300))]),
    )
  let assert Ok(Nil) = runtime.send_frame(rt, ex1, "ctx", call_slow, 1000)

  // Cancel it immediately
  let ex2 = server.fresh_exchange()
  let cancel_frame =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("method", json.string("notifications/cancelled")),
      #("params", json.object([#("requestId", json.string("cancel-req-1"))])),
    ])
    |> json.to_string()
    |> bit_array.from_string()

  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "ctx", cancel_frame, 1000)

  // Wait 400ms: ensure NO completion message is received for cancel-req-1!
  case process.receive(sink_subj, 400) {
    Ok(_) -> should.fail()
    Error(Nil) -> Nil
  }

  runtime.stop(rt, 1000)
}

pub fn runtime_frame_bound_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config =
    RuntimeConfig(
      max_live_exchanges: 10,
      max_frame_bytes: 20,
      // very small
      invocation_timeout_ms: 1000,
      tombstone_retention_ms: 1000,
    )

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  let ex = server.fresh_exchange()
  let large_frame = make_discover_frame("large-1")
  let res = runtime.send_frame(rt, ex, "ctx", large_frame, 1000)
  case res {
    Error(runtime.FrameTooLarge(_, _)) -> Nil
    _ -> should.fail()
  }

  runtime.stop(rt, 1000)
}

pub fn runtime_equal_wire_ids_on_distinct_exchanges_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  // Two distinct exchanges with same JSON-RPC id: "same-id"
  let ex1 = server.fresh_exchange()
  let ex2 = server.fresh_exchange()

  let f1 =
    make_call_frame(
      "same-id",
      "greet",
      json.object([#("name", json.string("User1"))]),
    )
  let f2 =
    make_call_frame(
      "same-id",
      "greet",
      json.object([#("name", json.string("User2"))]),
    )

  let assert Ok(Nil) = runtime.send_frame(rt, ex1, "ctx1", f1, 1000)
  let assert Ok(Nil) = runtime.send_frame(rt, ex2, "ctx2", f2, 1000)

  let assert Ok(out1) = process.receive(sink_subj, 1000)
  let assert Ok(out2) = process.receive(sink_subj, 1000)

  let assert Ok(str1) = bit_array.to_string(out1)
  let assert Ok(str2) = bit_array.to_string(out2)

  // Both completed successfully
  let assert True =
    string.contains(str1, "User1") || string.contains(str2, "User1")
  let assert True =
    string.contains(str1, "User2") || string.contains(str2, "User2")

  runtime.stop(rt, 1000)
}

pub fn runtime_repeated_close_test() {
  let s = sample_server()
  let sink_subj = process.new_subject()
  let config = runtime.default_config()

  let assert Ok(rt) =
    runtime.start(s, config, fn(output) { send_output_to(sink_subj, output) })

  runtime.close(rt)
  runtime.close(rt)
  runtime.close(rt)

  // Subsequent frame submissions reject with RuntimeStopped
  let ex = server.fresh_exchange()
  let res = runtime.send_frame(rt, ex, "ctx", make_discover_frame("1"), 1000)
  res |> should.equal(Error(runtime.RuntimeStopped))

  runtime.stop(rt, 1000)
}

pub fn runtime_progress_backpressure_bounds_mailbox_test() {
  let notices = process.new_subject()
  let observations = process.new_subject()
  let gate = start_sink_gate()
  let assert Ok(name) = tool.tool_name("progress_burst")
  let assert Ok(tool) = case
    tool.definition(name, codec.success(Nil), codec.success(Nil))
  {
    Ok(definition) -> {
      let definition = tool.with_metadata(definition, tool.empty_metadata())
      Ok({
        let user_handler = fn(notices, _input, report_progress) {
          report_progress_burst(report_progress, 1, 128)
          process.send(notices, ProgressBurstFinished)
          Ok(Nil)
        }
        let advanced_handler = fn(call, typed_input) {
          let tool.HandlerCallContext(
            application,
            _input_responses,
            report_progress,
          ) = call
          user_handler(application, typed_input, report_progress)
          |> result.map(fn(output) { tool.Complete(output, []) })
        }
        tool.handle_advanced_with_error_renderer(
          definition,
          advanced_handler,
          fn(application_error) {
            case codec.encode_json(codec.success(Nil), application_error) {
              Ok(text) -> text
              Error(_) -> "Tool execution failed."
            }
          },
        )
      })
    }
    Error(error) -> Error(error)
  }
  let assert Ok(registry) = tool.registry([tool])
  let config =
    RuntimeConfig(..runtime.default_config(), invocation_timeout_ms: 5000)
  let assert Ok(rt) =
    runtime.start(server.server(registry), config, fn(output) {
      case output {
        runtime.OutputClose(_) -> Ok(Nil)
        runtime.OutputWrite(_, _) -> {
          let hold =
            process.call_forever(gate, fn(reply) { DecideToHold(reply) })
          case hold {
            False -> Nil
            True -> {
              // Keep the writer parked while the producer has a chance to offer
              // the rest of its burst, then inspect the runtime owner's mailbox.
              process.sleep(100)
              let queued = ffi_mailbox_size(ffi_self())
              let release = process.new_subject()
              process.send(observations, #(queued, release))
              let _ = process.receive(release, 5000)
              Nil
            }
          }
          Ok(Nil)
        }
      }
    })
  let exchange = server.fresh_exchange()
  let assert Ok(Nil) =
    runtime.send_frame(
      rt,
      exchange,
      notices,
      progress_call_frame("progress-burst"),
      1000,
    )
  let assert Ok(#(queued, release)) = process.receive(observations, 3000)
  process.send(release, Nil)
  let assert Ok(ProgressBurstFinished) = process.receive(notices, 5000)
  runtime.stop(rt, 1000)
  stop_sink_gate(gate)
  should.be_true(queued <= 1)
}

fn progress_call_frame(id: String) -> BitArray {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.string(id)),
    #("method", json.string("tools/call")),
    #(
      "params",
      json.object([
        #("name", json.string("progress_burst")),
        #("arguments", json.object([])),
        #(
          "_meta",
          json.object([
            #(
              "io.modelcontextprotocol/protocolVersion",
              json.string("2026-07-28"),
            ),
            #("io.modelcontextprotocol/clientCapabilities", json.object([])),
            #("progressToken", json.int(1)),
          ]),
        ),
      ]),
    ),
  ])
  |> json.to_string()
  |> bit_array.from_string()
}

fn report_progress_burst(
  report_progress: fn(Int) -> Nil,
  current: Int,
  last: Int,
) -> Nil {
  case current > last {
    True -> Nil
    False -> {
      report_progress(current)
      report_progress_burst(report_progress, current + 1, last)
    }
  }
}

fn start_sink_gate() -> process.Subject(SinkGateMessage) {
  let ready = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let subject = process.new_subject()
      process.send(ready, subject)
      sink_gate_loop(subject, True)
    })
  let assert Ok(subject) = process.receive(ready, 1000)
  subject
}

fn sink_gate_loop(
  subject: process.Subject(SinkGateMessage),
  first: Bool,
) -> Nil {
  case process.receive(subject, 10_000) {
    Error(_) -> Nil
    Ok(DecideToHold(reply)) -> {
      process.send(reply, first)
      sink_gate_loop(subject, False)
    }
    Ok(StopSinkGate(reply)) -> process.send(reply, Nil)
  }
}

fn stop_sink_gate(gate: process.Subject(SinkGateMessage)) -> Nil {
  let reply = process.new_subject()
  process.send(gate, StopSinkGate(reply))
  let _ = process.receive(reply, 1000)
  Nil
}
