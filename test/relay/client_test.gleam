import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import http_gun/cancellation
import http_gun/deadline
import json/blueprint/codec.{type Codec}
import json/blueprint/number
import json/blueprint/value
import relay/authorization
import relay/client
import relay/completion
import relay/content
import relay/http
import relay/prompts
import relay/resources
import relay/server
import relay/subscriptions
import relay/telemetry
import relay/testing
import relay/tool
import sinal
import sinal/correlation

@external(erlang, "relay_http_ffi", "disconnect_after_first_sse_event")
fn disconnect_after_first_sse_event(
  port: Int,
  method: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Int, String)

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

// --- fixtures ----------------------------------------------------------------

fn property(name: String, inner: Codec(a)) -> Codec(a) {
  use value <- codec.field(name, inner, get: fn(value) { value })
  codec.success(value)
}

fn named_input() -> Codec(String) {
  property("name", codec.string())
}

fn echo_definition() -> tool.Definition(String, String) {
  tool.define("echo", named_input(), codec.string())
}

fn fail_definition() -> tool.Definition(String, String) {
  tool.define("fail", named_input(), codec.string())
}

fn default_error_definition() -> tool.Definition(String, String) {
  tool.define("default_error", named_input(), codec.string())
}

fn say_definition() -> tool.Definition(String, List(content.ContentBlock)) {
  tool.define_content("say", named_input())
}

fn rich_definition() -> tool.Definition(String, List(content.ContentBlock)) {
  tool.define_content("rich", named_input())
}

fn exact_definition() -> tool.Definition(number.Number, number.Number) {
  tool.define("exact", property("value", codec.number()), codec.number())
}

fn slow_definition() -> tool.Definition(String, String) {
  tool.define("slow", named_input(), codec.string())
}

fn fail_error_codec() -> Codec(#(String, String)) {
  use code <- codec.field("code", codec.string(), get: fn(error) { error.0 })
  use message <- codec.field("message", codec.string(), get: fn(error) {
    error.1
  })
  codec.success(#(code, message))
}

fn rich_annotations() -> content.Annotations {
  content.Annotations(
    audience: [content.UserRole, content.AssistantRole],
    priority: Some(0.75),
    last_modified: None,
  )
}

fn rich_blocks() -> List(content.ContentBlock) {
  [
    content.image(<<"hello">>, "image/png")
      |> content.with_annotations(rich_annotations()),
    content.audio(<<1, 2, 3>>, "audio/wav"),
    content.resource_link("https://example.test/resource", "linked"),
    content.embedded(
      content.TextResourceContents(
        uri: "file:///embedded",
        text: "embedded text",
        mime_type: Some("text/plain"),
        meta: [],
      ),
    ),
  ]
}

// A tool that waits for its cancellation and reports it to `observed`.
fn slow_tool(observed: Subject(String)) -> tool.Tool(context) {
  slow_definition()
  |> tool.handle_call(fn(call, _name) {
    case process.selector_receive(tool.cancelled(call), 3000) {
      Ok(Nil) -> {
        process.send(observed, "cancelled")
        Ok(tool.complete("cancelled"))
      }
      Error(Nil) -> Ok(tool.complete("finished"))
    }
  })
}

fn local_tools(observed: Subject(String)) -> List(tool.Tool(context)) {
  [
    echo_definition() |> tool.handle(fn(name) { Ok("hello " <> name) }),
    fail_definition()
      |> tool.handle_with_error_renderer(
        fn(_name) {
          Error(#("not_found", "The requested record is unavailable."))
        },
        fn(error) {
          let assert Ok(text) = codec.encode_json(fail_error_codec(), error)
          tool.error_message(text)
        },
      ),
    default_error_definition()
      |> tool.handle(fn(_name) { Error("private secret") }),
    say_definition()
      |> tool.handle(fn(_name) { Ok([content.text("content-only reply")]) }),
    rich_definition() |> tool.handle(fn(_name) { Ok(rich_blocks()) }),
    exact_definition() |> tool.handle(Ok),
    slow_tool(observed),
    ..many_named_tools(101)
  ]
}

fn many_named_tools(count: Int) -> List(tool.Tool(context)) {
  case count <= 0 {
    True -> []
    False -> [
      tool.define(
        "list-" <> int.to_string(count),
        named_input(),
        codec.string(),
      )
        |> tool.handle(Ok),
      ..many_named_tools(count - 1)
    ]
  }
}

fn local_server(observed: Subject(String)) -> server.Server(context) {
  let readable =
    resources.static("memory://client-note", "client note", fn(_context, uri) {
      Ok([
        content.TextResourceContents(
          uri,
          "client resource",
          Some("text/plain"),
          [],
        ),
      ])
    })
  let template =
    resources.template(
      "memory://client/{name}",
      "client resource template",
      fn(_context, uri) {
        Ok([
          content.TextResourceContents(
            uri,
            "template resource",
            Some("text/plain"),
            [],
          ),
        ])
      },
    )
  let prompt =
    prompts.prompt("client-prompt", [], fn(_context, _arguments) {
      Ok(
        prompts.PromptResult(
          Some("client prompt"),
          [prompts.user_message("greeting")],
          [],
        ),
      )
    })
  let completer =
    completion.completion(fn(_context, request: completion.Request) {
      Ok(completion.Values([request.value <> "-next"], Some(1), Some(False)))
    })
  server.new(local_tools(observed))
  |> server.with_resources([readable, template])
  |> server.with_prompts([prompt])
  |> server.with_completion(completer)
}

fn start_http(service: server.Server(Nil)) -> #(http.Handler(Nil), String) {
  let assert Ok(handler) = http.start(http.new(service))
  #(handler, url_of(handler))
}

fn url_of(handler: http.Handler(context)) -> String {
  "http://127.0.0.1:" <> int.to_string(http.port(handler)) <> "/"
}

fn connect_url(url: String) -> client.Client {
  let assert Ok(config) = client.http(url)
  let assert Ok(peer) = client.connect(config)
  peer
}

fn runner_config() -> client.Config {
  client.stdio("./test/fixtures/stdio/relay-stdio", [])
}

fn connect_runner() -> client.Client {
  let assert Ok(peer) = client.connect(runner_config())
  peer
}

// A stdio peer that answers every request with this result object.
fn answering_peer(result: String) -> client.Config {
  client.stdio("python3", [
    "-c",
    "import json, sys\nfor line in sys.stdin:\n    request = json.loads(line)\n    if 'id' in request:\n        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': json.loads(sys.argv[1])}), flush=True)\n",
    result,
  ])
}

fn runner_property_definition(
  name: String,
  key: String,
) -> tool.Definition(Int, String) {
  tool.define(name, property(key, codec.int()), codec.string())
}

// --- errors ------------------------------------------------------------------

pub fn error_classification_test() {
  let assert client.Configuration =
    client.kind(client.InvalidConfig(client.Url))
  let assert client.Unreachable = client.kind(client.ConnectFailed)
  let assert client.Unreachable =
    client.kind(client.ConnectionClosed(client.MaybeSent))
  let assert client.Timeout = client.kind(client.TimedOut(client.MaybeSent))
  let assert client.Cancellation = client.kind(client.Cancelled(client.NotSent))
  let assert client.Overloaded = client.kind(client.TooManyPendingCalls(1))
  let assert client.Rejected = client.kind(client.HttpStatus(401, None))
  let assert client.Protocol = client.kind(client.RpcError(-32_602, "x", None))
  let assert client.Protocol = client.kind(client.UnsupportedVersion([]))
  let assert client.InvalidInput = client.kind(client.InvalidInputResponses)
  let assert client.TooLarge = client.kind(client.ListingLimitExceeded(3))

  let assert client.NotSent = client.evidence(client.ConnectFailed)
  let assert client.NotSent = client.evidence(client.InvalidArguments("x"))
  let assert client.MaybeSent =
    client.evidence(client.TimedOut(client.MaybeSent))
  let assert client.MaybeSent = client.evidence(client.ResponseTooLarge(8))
  let assert client.Completed = client.evidence(client.HttpStatus(500, None))
  let assert client.Completed =
    client.evidence(client.RpcError(-32_602, "x", None))

  let assert True = client.is_retryable(client.ConnectFailed, idempotent: False)
  let assert False =
    client.is_retryable(client.TimedOut(client.MaybeSent), idempotent: False)
  let assert True =
    client.is_retryable(client.TimedOut(client.MaybeSent), idempotent: True)
  let assert True =
    client.is_retryable(client.TooManyPendingCalls(1), idempotent: False)
  let assert True =
    client.is_retryable(client.HttpStatus(503, None), idempotent: False)
  let assert True =
    client.is_retryable(client.HttpStatus(429, None), idempotent: False)
  let assert False =
    client.is_retryable(client.HttpStatus(401, None), idempotent: True)
  let assert False =
    client.is_retryable(client.RpcError(-32_602, "x", None), idempotent: True)

  let assert "timed_out.maybe_sent" =
    client.name(client.TimedOut(client.MaybeSent))
  let assert "connection_closed.not_sent" =
    client.name(client.ConnectionClosed(client.NotSent))
  let assert "http_status.401" = client.name(client.HttpStatus(401, None))
  let assert "rpc_error.-32602" =
    client.name(client.RpcError(-32_602, "x", None))
  let assert "connect_failed" = client.name(client.ConnectFailed)

  let assert "the MCP server answered HTTP 401" =
    client.describe_error(client.HttpStatus(401, Some("Bearer")))
  let assert "the MCP server answered JSON-RPC error -32602: Invalid params" =
    client.describe_error(client.RpcError(-32_602, "Invalid params", None))
  let assert "invalid Relay client setting: the URL" =
    client.describe_error(client.InvalidConfig(client.Url))
}

pub fn unreachable_http_server_fails_on_first_call_test() {
  // Connecting is lazy: the unreachable port fails on the first call.
  let peer = connect_url("http://127.0.0.1:1/")
  let assert Error(error) = client.discover(peer)
  let assert client.ConnectFailed = error
  let assert client.NotSent = client.evidence(error)
  let assert client.Unreachable = client.kind(error)
  let assert True = client.is_retryable(error, idempotent: False)
  client.close(peer)
}

pub fn protected_server_answers_401_with_its_challenge_test() {
  let assert Ok(resource) =
    authorization.protected_resource("https://mcp.example.test/mcp")
  let protection = authorization.protection(resource, [])
  let verifier =
    testing.verifier([
      #(
        "good",
        authorization.attestation("ada", ["https://mcp.example.test/mcp"], []),
      ),
    ])
  let assert Ok(handler) =
    http.start(
      http.new_protected(
        server.new([echo_definition() |> tool.handle(fn(n) { Ok("hi " <> n) })]),
        verifier,
        protection,
        fn(_request, grant) { Ok(authorization.grant_principal(grant)) },
      ),
    )
  let url = url_of(handler)

  // No token: 401 with the RFC 9728 metadata challenge.
  let anonymous = connect_url(url)
  let assert Error(client.HttpStatus(401, Some(challenge))) =
    client.discover(anonymous)
  let assert True = string.starts_with(challenge, "Bearer ")
  let assert True = string.contains(challenge, "resource_metadata=")
  client.close(anonymous)

  // A good token gets through.
  let assert Ok(config) = client.http(url)
  let assert Ok(authorized) =
    config
    |> client.with_headers(fn() { [#("authorization", "Bearer good")] })
    |> client.connect
  let assert Ok(client.Succeeded("hi Ada", _)) =
    client.call(authorized, echo_definition(), "Ada")
  client.close(authorized)

  // Headers are computed for each request: the first token is bad, the
  // second good.
  let tokens = process.new_subject()
  process.send(tokens, "bad")
  process.send(tokens, "good")
  let assert Ok(refreshing) =
    config
    |> client.with_headers(fn() {
      let assert Ok(token) = process.receive(tokens, 0)
      [#("authorization", "Bearer " <> token)]
    })
    |> client.connect
  let assert Error(client.HttpStatus(401, Some(rejected))) =
    client.discover(refreshing)
  let assert True = string.contains(rejected, "invalid_token")
  let assert Ok(_) = client.discover(refreshing)
  client.close(refreshing)
  http.stop(handler)
}

pub fn json_rpc_errors_arrive_as_rpc_error_test() {
  let needs_elicitation =
    tool.define("needs_elicitation", named_input(), codec.string())
    |> tool.with_required_client_capabilities(["elicitation"])
    |> tool.handle(Ok)
  let peer = testing.connect(server.new([needs_elicitation]), Nil)

  // An unknown tool is invalid params.
  let assert Error(client.RpcError(-32_602, _, _)) =
    client.call(peer, echo_definition(), "nobody")

  // A missing client capability names the capability in `data`.
  let assert Error(client.RpcError(-32_021, _, Some(data))) =
    client.call(
      peer,
      tool.define("needs_elicitation", named_input(), codec.string()),
      "x",
    )
  let assert value.Object([
    #(
      "requiredCapabilities",
      value.Object([#("elicitation", value.Object([]))]),
    ),
  ]) = data
  client.close(peer)
}

// --- deadlines, cancellation and correlation ---------------------------------

pub fn http_deadline_ends_the_call_and_cancels_the_handler_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let peer = connect_url(url)
  let started = monotonic_ms()
  let assert Error(client.TimedOut(_)) =
    peer
    |> client.with_deadline(deadline.after(duration.milliseconds(300)))
    |> client.call(slow_definition(), "late")
  let elapsed = monotonic_ms() - started
  let assert True = elapsed >= 250 && elapsed < 1500
  // MCP cancels by closing the connection: the handler sees it.
  let assert Ok("cancelled") = process.receive(observed, 2000)
  // The next call on the same client reconnects.
  let assert Ok(client.Succeeded("hello again", _)) =
    client.call(peer, echo_definition(), "again")
  client.close(peer)
  http.stop(handler)
}

pub fn http_cancellation_ends_the_call_and_cancels_the_handler_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let peer = connect_url(url)
  let outcome = {
    use token <- cancellation.with_token
    let _ =
      process.spawn(fn() {
        process.sleep(500)
        cancellation.cancel(token)
      })
    peer
    |> client.with_cancellation(token)
    |> client.call(slow_definition(), "cancel me")
  }
  let assert Error(client.Cancelled(_)) = outcome
  let assert Ok("cancelled") = process.receive(observed, 2000)
  let assert Ok(client.Succeeded("hello after", _)) =
    client.call(peer, echo_definition(), "after")
  client.close(peer)
  http.stop(handler)
}

/// Closing a client cancels its in-flight HTTP calls at once: each call's
/// connection closes, which cancels it on the server, and `close` does not
/// wait for the response to drain.
pub fn http_close_cancels_in_flight_calls_without_draining_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let peer = connect_url(url)
  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(done, client.call(peer, slow_definition(), "in flight"))
    })
  // Let the request reach the handler.
  process.sleep(300)
  let closing = monotonic_ms()
  client.close(peer)
  let closed_in = monotonic_ms() - closing
  let outcome = process.receive(done, 2000)
  let cancelled = process.receive(observed, 2000)
  http.stop(handler)
  let assert True = closed_in < 1000
  let assert Ok(Error(client.Cancelled(client.MaybeSent))) = outcome
  let assert Ok("cancelled") = cancelled
}

pub fn in_process_close_cancels_in_flight_calls_at_once_test() {
  let observed = process.new_subject()
  let peer = testing.connect(local_server(observed), Nil)
  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(done, client.call(peer, slow_definition(), "in flight"))
    })
  process.sleep(200)
  let closing = monotonic_ms()
  client.close(peer)
  let closed_in = monotonic_ms() - closing
  let assert True = closed_in < 500
  let assert Ok(Error(client.Cancelled(client.MaybeSent))) =
    process.receive(done, 1000)
  let assert Ok("cancelled") = process.receive(observed, 2000)
}

pub fn in_process_deadline_and_cancellation_cancel_the_handler_test() {
  let observed = process.new_subject()
  let peer = testing.connect(local_server(observed), Nil)
  let assert Error(client.TimedOut(_)) =
    peer
    |> client.with_deadline(deadline.after(duration.milliseconds(200)))
    |> client.call(slow_definition(), "late")
  let assert Ok("cancelled") = process.receive(observed, 2000)
  let outcome = {
    use token <- cancellation.with_token
    let _ =
      process.spawn(fn() {
        process.sleep(150)
        cancellation.cancel(token)
      })
    peer
    |> client.with_cancellation(token)
    |> client.call(slow_definition(), "cancel me")
  }
  let assert Error(client.Cancelled(_)) = outcome
  let assert Ok("cancelled") = process.receive(observed, 2000)
  client.close(peer)
}

pub fn stdio_cancellation_reaches_the_child_test() {
  let peer = connect_runner()
  let outcome = {
    use token <- cancellation.with_token
    let _ =
      process.spawn(fn() {
        process.sleep(300)
        cancellation.cancel(token)
      })
    peer
    |> client.with_cancellation(token)
    |> client.call(runner_property_definition("wait", "ms"), 3000)
  }
  let assert Error(client.Cancelled(_)) = outcome
  // The child received notifications/cancelled: its handler saw the
  // cancellation and recorded it.
  let was_cancelled =
    tool.define("was_cancelled", codec.success(Nil), codec.bool())
  let assert Ok(client.Succeeded(True, _)) =
    wait_until_cancelled(peer, was_cancelled, 20)
  client.close(peer)
}

fn wait_until_cancelled(
  peer: client.Client,
  definition: tool.Definition(Nil, Bool),
  attempts: Int,
) -> Result(client.ToolResult(Bool), client.Error) {
  case client.call(peer, definition, Nil) {
    Ok(client.Succeeded(False, _)) if attempts > 0 -> {
      process.sleep(50)
      wait_until_cancelled(peer, definition, attempts - 1)
    }
    other -> other
  }
}

pub fn correlation_reaches_the_handler_and_client_telemetry_test() {
  let whoami =
    tool.define("whoami", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(call, _) {
      Ok(
        tool.complete(case tool.correlation(call) {
          Some(found) -> correlation.to_string(found)
          None -> "none"
        }),
      )
    })
  let ask =
    tool.define("ask", codec.success(Nil), codec.string())
    |> tool.handle_call(fn(_call, _) {
      Ok(
        tool.request_input(
          dict.from_list([
            #(
              "confirm",
              tool.InputRequest(
                tool.Elicitation,
                value.Object([#("message", value.String("ok?"))]),
              ),
            ),
          ]),
        ),
      )
    })
  let service =
    server.new([
      whoami,
      ask,
      fail_definition()
        |> tool.handle(fn(_) { Error(Nil) }),
    ])
  let assert Ok(peer) =
    client.in_process(service, Nil)
    |> client.with_label("correlated-client")
    |> client.with_input_methods([tool.Elicitation])
    |> client.connect
  let tag = correlation.from_key("client-test-correlation")
  let tagged = client.with_correlation(peer, tag)

  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.client_call_event(), fn(_measurements, meta) {
      case meta.client {
        Some("correlated-client") -> process.send(events, meta)
        _ -> Nil
      }
    })

  let whoami_definition =
    tool.define("whoami", codec.success(Nil), codec.string())
  let assert Ok(client.Succeeded(seen, _)) =
    client.call(tagged, whoami_definition, Nil)
  let assert True = seen == correlation.to_string(tag)
  let assert Ok(client.Succeeded("none", _)) =
    client.call(peer, whoami_definition, Nil)
  let assert Ok(client.ToolFailed(_, _)) =
    client.call(tagged, fail_definition(), "x")
  let assert Ok(client.InputRequired(_, _)) =
    client.call(
      tagged,
      tool.define("ask", codec.success(Nil), codec.string()),
      Nil,
    )
  let assert Error(client.RpcError(..)) =
    client.call(tagged, echo_definition(), "x")
  let assert Ok(_) = client.discover(tagged)
  let _ = sinal.detach(attachment)

  let metas = drain(events, [])
  let assert [first, untagged, failed, input, rpc, discovered] = metas
  let assert telemetry.ClientCallMeta(
    "tools/call",
    Some("whoami"),
    telemetry.CallCompleted,
    Some(_),
    Some("correlated-client"),
  ) = first
  let assert telemetry.ClientCallMeta(
    "tools/call",
    Some("whoami"),
    telemetry.CallCompleted,
    None,
    _,
  ) = untagged
  let assert telemetry.ClientCallMeta(
    "tools/call",
    Some("fail"),
    telemetry.CallToolFailed,
    Some(_),
    _,
  ) = failed
  let assert telemetry.ClientCallMeta(
    "tools/call",
    Some("ask"),
    telemetry.CallInputRequired,
    Some(_),
    _,
  ) = input
  let assert telemetry.ClientCallMeta(
    "tools/call",
    Some("echo"),
    telemetry.CallFailed,
    Some(_),
    _,
  ) = rpc
  let assert telemetry.ClientCallMeta(
    "server/discover",
    None,
    telemetry.CallCompleted,
    Some(found),
    _,
  ) = discovered
  let assert True = correlation.to_string(found) == correlation.to_string(tag)
  client.close(peer)
}

fn drain(subject: Subject(a), acc: List(a)) -> List(a) {
  case process.receive(subject, 100) {
    Ok(item) -> drain(subject, [item, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

// --- calls -------------------------------------------------------------------

pub fn http_client_discovery_and_typed_calls_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let peer = connect_url(url)

  let assert Ok(discovery) = client.discover(peer)
  let assert True = list.contains(discovery.supported_versions, "2026-07-28")

  let assert Ok([
    content.TextResourceContents(
      "memory://client-note",
      "client resource",
      Some("text/plain"),
      [],
    ),
  ]) = client.read_resource(peer, "memory://client-note")
  let assert Ok(prompts.PromptResult(
    Some("client prompt"),
    [
      prompts.PromptMessage(
        content.UserRole,
        content.TextContent("greeting", None, []),
      ),
    ],
    [],
  )) = client.get_prompt(peer, "client-prompt", dict.new())
  let assert Ok(completion.Values(["gleam-next"], Some(1), Some(False))) =
    client.complete(
      peer,
      completion.Request(
        completion.PromptReference("client-prompt"),
        "topic",
        "gleam",
        dict.new(),
      ),
    )

  let assert Ok(echoed) = client.call(peer, echo_definition(), "MCP")
  let assert client.Succeeded(
    "hello MCP",
    [content.TextContent("hello MCP", None, [])],
  ) = echoed

  let assert Ok(client.ToolFailed(
    [content.TextContent(error_json, None, [])],
    None,
  )) = client.call(peer, fail_definition(), "MCP")
  let assert Ok(#("not_found", "The requested record is unavailable.")) =
    codec.decode_json(fail_error_codec(), error_json)

  let assert Ok(client.ToolFailed(
    [content.TextContent("Tool execution failed.", None, [])],
    None,
  )) = client.call(peer, default_error_definition(), "MCP")

  let assert Ok(client.Succeeded(
    [content.TextContent("content-only reply", None, [])],
    [content.TextContent("content-only reply", None, [])],
  )) = client.call(peer, say_definition(), "MCP")

  let assert Ok(client.Succeeded(blocks, content_blocks)) =
    client.call(peer, rich_definition(), "MCP")
  let assert True = blocks == rich_blocks()
  let assert True = content_blocks == rich_blocks()

  // Big numbers keep every digit, typed and discovered.
  let exact_token =
    "1234567890123456789012345678901234567890.1234567890123456789"
  let assert Ok(exact) =
    number.parse(exact_token, number.limits(1024, 100, 1000))
  let assert Ok(client.Succeeded(typed, _)) =
    client.call(peer, exact_definition(), exact)
  let assert True = typed == exact
  let assert Ok(declarations) = client.list_tools(peer)
  let assert [exact_declaration] =
    list.filter(declarations, fn(declaration) { declaration.name == "exact" })
  let assert Ok(client.Succeeded(value.Number(discovered), _)) =
    client.call_discovered(
      peer,
      exact_declaration,
      value.Object([#("value", value.Number(exact))]),
    )
  let assert True = discovered == exact

  // A short client timeout ends a slow call.
  let assert Ok(config) = client.http(url)
  let assert Ok(timeout_peer) =
    config
    |> client.with_timeout(duration.milliseconds(300))
    |> client.connect
  let assert Error(client.TimedOut(_)) =
    client.call(timeout_peer, slow_definition(), "MCP")
  let assert Ok("cancelled") = process.receive(observed, 2000)
  client.close(timeout_peer)

  // A response beyond the client's byte limit.
  let assert Ok(bounded) =
    config
    |> client.with_max_response_bytes(8)
    |> client.connect
  let assert Error(client.ResponseTooLarge(8)) = client.discover(bounded)
  client.close(bounded)

  client.close(peer)
  http.stop(handler)
}

pub fn raw_calls_and_listings_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let peer = connect_url(url)

  let assert Ok(value.Object(discovery)) =
    client.call_raw(peer, "server/discover", None, [])
  let assert Ok(_) = list.key_find(discovery, "supportedVersions")

  let assert Ok(value.Object(page)) =
    client.call_raw(peer, "tools/list", None, [])
  let assert Ok(value.String(cursor)) = list.key_find(page, "nextCursor")
  // A cursor from another listing family, and a forged one, are refused.
  let assert Error(client.RpcError(..)) =
    client.call_raw(peer, "prompts/list", None, [
      #("cursor", json.string(cursor)),
    ])
  let assert Error(client.RpcError(..)) =
    client.call_raw(peer, "tools/list", None, [
      #("cursor", json.string("invalid-cursor")),
    ])

  // The default error text, through the raw call.
  let assert Ok(value.Object(failed)) =
    client.call_raw(peer, "tools/call", Some("default_error"), [
      #("name", json.string("default_error")),
      #("arguments", json.object([#("name", json.string("MCP"))])),
    ])
  let assert Ok(value.Bool(True)) = list.key_find(failed, "isError")
  let assert Error(client.InvalidArguments(_)) =
    client.call_raw(peer, "tools/call", None, [])
  let assert Error(client.InvalidArguments(_)) =
    client.call_raw(peer, "tools/list", Some("echo"), [])

  let assert Ok(tools) = client.list_tools(peer)
  let assert 108 = list.length(tools)
  let assert True =
    list.any(tools, fn(declaration) { declaration.name == "list-1" })
  let assert Ok(raw_tools) = client.list_raw(peer, "tools/list", "tools")
  let assert 108 = list.length(raw_tools)
  let assert Ok(resource_list) = client.list_resources(peer)
  let assert True =
    list.any(resource_list, fn(resource) {
      resource.uri == "memory://client-note"
    })
  let assert Ok(template_list) = client.list_resource_templates(peer)
  let assert True =
    list.any(template_list, fn(template) {
      template.uri_template == "memory://client/{name}"
    })
  let assert Ok(prompt_list) = client.list_prompts(peer)
  let assert True =
    list.any(prompt_list, fn(prompt) { prompt.name == "client-prompt" })

  // The input schema is an exact Value that loads as a contract.
  let assert [echo_declaration] =
    list.filter(tools, fn(declaration) { declaration.name == "echo" })
  let assert value.Object(_) = echo_declaration.input_schema
  let assert Ok(_) = tool.input_contract(echo_declaration)
  let assert value.Object(schema) = echo_declaration.input_schema
  let assert Ok(value.String("object")) = list.key_find(schema, "type")
  let assert Ok(value.Object(properties)) = list.key_find(schema, "properties")
  let assert Ok(_) = list.key_find(properties, "name")

  client.close(peer)
  http.stop(handler)
}

pub fn admitted_definition_uses_plain_mcp_errors_and_typed_client_call_test() {
  let input = named_input()
  let success = tool.define("definition_success", input, codec.string())
  let default = tool.define("definition_default_error", input, codec.string())
  let rendered = tool.define("definition_rendered_error", input, codec.string())
  let service =
    server.new([
      tool.handle(success, fn(name) { Ok("hello " <> name) }),
      tool.handle(default, fn(_name) { Error("private secret") }),
      tool.handle_with_error_renderer(
        rendered,
        fn(_name) { Error("record missing") },
        fn(error) { tool.error_message("Public: " <> error) },
      ),
    ])
  let #(handler, url) = start_http(service)
  let peer = connect_url(url)
  let assert Ok(client.Succeeded("hello world", [first])) =
    client.call(peer, success, "world")
  let assert True = first == content.text("hello world")
  let assert Ok(client.ToolFailed([default_block], None)) =
    client.call(peer, default, "world")
  let assert True = default_block == content.text("Tool execution failed.")
  let assert Ok(client.ToolFailed([rendered_block], None)) =
    client.call(peer, rendered, "world")
  let assert True = rendered_block == content.text("Public: record missing")
  client.close(peer)
  http.stop(handler)
}

pub fn call_discovered_and_listing_bounds_are_explicit_test() {
  let observed = process.new_subject()
  let #(handler, url) = start_http(local_server(observed))
  let assert Ok(base) = client.http(url)
  let assert Ok(peer) = client.connect(base)
  let assert Ok(declarations) = client.list_tools(peer)
  let assert [echo_declaration] =
    list.filter(declarations, fn(declaration) { declaration.name == "echo" })
  let assert Ok(client.Succeeded(value.String("hello remote"), [block])) =
    client.call_discovered(
      peer,
      echo_declaration,
      value.Object([#("name", value.String("remote"))]),
    )
  let assert True = block == content.text("hello remote")
  // A content-only result has a Null output.
  let assert [say_declaration] =
    list.filter(declarations, fn(declaration) { declaration.name == "say" })
  let assert Ok(client.Succeeded(value.Null, _)) =
    client.call_discovered(
      peer,
      say_declaration,
      value.Object([#("name", value.String("remote"))]),
    )
  let assert Error(client.InvalidArguments(_)) =
    client.call_discovered(
      peer,
      echo_declaration,
      value.String("not arguments"),
    )
  let assert Error(client.InvalidArguments(_)) =
    client.call_discovered(peer, echo_declaration, value.Array([]))

  let assert Ok(item_limited) =
    base |> client.with_listing_limits(256, 3) |> client.connect
  let assert Error(client.ListingLimitExceeded(3)) =
    client.list_tools(item_limited)
  let assert Error(client.ListingLimitExceeded(3)) =
    client.list_raw(item_limited, "tools/list", "tools")
  client.close(item_limited)
  let assert Ok(page_limited) =
    base |> client.with_listing_limits(1, 10_000) |> client.connect
  let assert Error(client.ListingLimitExceeded(1)) =
    client.list_tools(page_limited)
  client.close(page_limited)

  client.close(peer)
  let assert Error(closed) =
    client.call_discovered(
      peer,
      echo_declaration,
      value.Object([#("name", value.String("closed"))]),
    )
  let assert client.Unreachable = client.kind(closed)
  http.stop(handler)
}

pub fn repeated_listing_cursor_is_malformed_test() {
  let assert Ok(peer) =
    client.connect(answering_peer("{\"tools\":[],\"nextCursor\":\"same\"}"))
  let assert Error(client.MalformedResponse(_)) = client.list_tools(peer)
  let assert Error(client.MalformedResponse(_)) =
    client.list_raw(peer, "tools/list", "tools")
  client.close(peer)
}

pub fn invalid_configuration_fails_before_transport_start_test() {
  let assert Ok(http_config) = client.http("http://127.0.0.1/")
  let assert Error(client.InvalidConfig(client.ListingLimits)) =
    http_config |> client.with_listing_limits(0, 1) |> client.connect
  let assert Error(client.InvalidConfig(client.ListingLimits)) =
    client.stdio("/bin/echo", [])
    |> client.with_listing_limits(1, 0)
    |> client.connect
  let assert Error(client.InvalidConfig(client.RequestTimeout)) =
    http_config
    |> client.with_timeout(duration.milliseconds(0))
    |> client.connect
  let assert Error(client.InvalidConfig(client.ConnectTimeout)) =
    http_config
    |> client.with_connect_timeout(duration.milliseconds(0))
    |> client.connect
  let assert Error(client.InvalidConfig(client.MaxResponseBytes)) =
    http_config |> client.with_max_response_bytes(0) |> client.connect
  let assert Error(client.InvalidConfig(client.MaxPendingCalls)) =
    client.stdio("/bin/echo", [])
    |> client.with_max_pending_calls(0)
    |> client.connect
  let assert Error(client.InvalidConfig(client.CaCertFile)) =
    http_config
    |> client.with_ca_cert_file("test/fixtures/tls/root-ca.crt")
    |> client.connect
  let assert Error(client.InvalidConfig(client.Url)) = client.http("ftp://x/")
  let assert Error(client.InvalidConfig(client.Url)) =
    client.http("http://127.0.0.1/?query")
  let assert Error(client.InvalidConfig(client.Url)) =
    client.http("http://user@127.0.0.1/")
}

pub fn configured_large_structured_response_uses_client_parser_bound_test() {
  let large_output = string.repeat("x", 10_486_000)
  let definition =
    tool.define("large-structured", named_input(), codec.string())
  let assert Ok(handler) =
    http.start(
      http.new(
        server.new([tool.handle(definition, fn(_name) { Ok(large_output) })]),
      )
      |> http.with_max_response_bytes(30_000_000),
    )
  let assert Ok(config) = client.http(url_of(handler))
  let assert Ok(peer) =
    config
    |> client.with_timeout(duration.seconds(15))
    |> client.with_max_response_bytes(30_000_000)
    |> client.connect
  let assert Ok(client.Succeeded(actual, _)) =
    client.call(peer, definition, "large")
  let assert 10_486_000 = string.byte_size(actual)
  client.close(peer)
  http.stop(handler)
}

// --- input rounds ------------------------------------------------------------

fn continuation_server() -> #(
  server.Server(Nil),
  tool.Definition(String, String),
) {
  let definition = tool.define("continue-echo", named_input(), codec.string())
  let bound =
    definition
    |> tool.handle_call(fn(call, name) {
      case dict.is_empty(tool.input_responses(call)) {
        True ->
          Ok(
            tool.request_input(
              dict.from_list([
                #(
                  "choice",
                  tool.InputRequest(
                    tool.Elicitation,
                    value.Object([
                      #("message", value.String("Continue?")),
                      #(
                        "requestedSchema",
                        value.Object([#("type", value.String("object"))]),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          )
        False ->
          Ok(
            tool.complete_with_content("continued " <> name, [
              content.text("rich continuation"),
            ]),
          )
      }
    })
  #(server.new([bound]), definition)
}

pub fn discovered_and_typed_tool_continuations_retain_state_test() {
  let #(service, definition) = continuation_server()
  let #(handler, url) = start_http(service)
  let assert Ok(base) = client.http(url)

  // A client that advertises no input method sees no requests.
  let assert Ok(unconfigured) = client.connect(base)
  let assert Ok(client.InputRequired(_, unconfigured_requests)) =
    client.call(unconfigured, definition, "unconfigured")
  let assert True = dict.is_empty(unconfigured_requests)
  client.close(unconfigured)

  let assert Ok(peer) =
    base
    |> client.with_input_methods([tool.Elicitation])
    |> client.connect
  let assert Ok([declaration]) = client.list_tools(peer)
  let assert Ok(client.InputRequired(continuation, requests)) =
    client.call(peer, definition, "typed")
  let assert Ok(tool.InputRequest(tool.Elicitation, value.Object(params))) =
    dict.get(requests, "choice")
  let assert Ok(value.String("Continue?")) = list.key_find(params, "message")

  let assert Error(client.InvalidInputResponses) =
    client.resume(continuation, dict.new())
  let assert Error(client.InvalidInputResponses) =
    client.resume(continuation, dict.from_list([#("wrong", json.object([]))]))
  let assert Error(client.InvalidInputResponses) =
    client.resume(
      continuation,
      dict.from_list([#("choice", json.string("no"))]),
    )

  let replies =
    dict.from_list([
      #(
        "choice",
        json.object([
          #("action", json.string("accept")),
          #("content", json.object([])),
        ]),
      ),
    ])
  let assert Ok(client.Succeeded("continued typed", [typed_block])) =
    client.resume(continuation, replies)
  let assert True = typed_block == content.text("rich continuation")

  let assert Ok(client.InputRequired(dynamic_continuation, _)) =
    client.call_discovered(
      peer,
      declaration,
      value.Object([#("name", value.String("dynamic"))]),
    )
  let assert Ok(client.Succeeded(value.String("continued dynamic"), [_])) =
    client.resume(dynamic_continuation, replies)
  client.close(peer)
  http.stop(handler)
}

fn input_peer(methods: List(tool.InputMethod)) -> client.Client {
  let assert Ok(peer) =
    client.stdio("python3", ["test/fixtures/stdio/input-required-peer.py"])
    |> client.with_input_methods(methods)
    |> client.connect
  peer
}

pub fn input_required_accepts_state_only_and_rejects_empty_result_test() {
  let peer = input_peer([])
  let state_only = tool.define("state-only", codec.success(Nil), codec.string())
  let assert Ok(client.InputRequired(continuation, requests)) =
    client.call(peer, state_only, Nil)
  let assert True = dict.is_empty(requests)
  let assert Ok(client.Succeeded("resumed", [])) =
    client.resume(continuation, dict.new())

  let empty = tool.define("empty-requests", codec.success(Nil), codec.string())
  let assert Ok(client.InputRequired(empty_continuation, empty_requests)) =
    client.call(peer, empty, Nil)
  let assert True = dict.is_empty(empty_requests)
  let assert Ok(client.Succeeded("resumed empty", [])) =
    client.resume(empty_continuation, dict.new())

  // An input_required result needs inputRequests or requestState.
  let invalid = tool.define("invalid", codec.success(Nil), codec.string())
  let assert Error(client.MalformedResponse(_)) =
    client.call(peer, invalid, Nil)
  client.close(peer)
}

pub fn content_only_continuation_test() {
  let peer = input_peer([tool.Roots])
  let definition = tool.define_content("content-only", codec.success(Nil))
  let assert Ok(client.InputRequired(continuation, requests)) =
    client.call(peer, definition, Nil)
  let assert Ok(tool.InputRequest(tool.Roots, value.Object([]))) =
    dict.get(requests, "root")
  let replies =
    dict.from_list([
      #("root", json.object([#("roots", json.preprocessed_array([]))])),
    ])
  let assert Ok(client.Succeeded([block], _)) =
    client.resume(continuation, replies)
  let assert True = block == content.text("content resumed")
  client.close(peer)
}

pub fn unadvertised_input_method_is_unsupported_test() {
  let peer = input_peer([tool.Elicitation])
  let definition = tool.define_content("content-only", codec.success(Nil))
  let assert Error(client.UnsupportedInputRequest("roots/list")) =
    client.call(peer, definition, Nil)
  client.close(peer)
}

pub fn non_object_arguments_are_invalid_test() {
  // Arguments that are not a JSON object fail before anything is sent.
  let peer = testing.connect(server.new([]), Nil)
  let declaration = tool.declaration(echo_definition())
  let assert Error(client.InvalidArguments(_)) =
    client.call_discovered(peer, declaration, value.Bool(True))
  let assert Error(client.InvalidArguments(_)) =
    client.call_discovered(peer, declaration, value.Null)
  client.close(peer)
}

// --- discovery ---------------------------------------------------------------

pub fn discover_reports_server_fields_test() {
  let service =
    server.new([echo_definition() |> tool.handle(Ok)])
    |> server.with_info("relay-test", "1.2.3")
    |> server.with_instructions("Call echo.")
  let peer = testing.connect(service, Nil)
  let assert Ok(discovery) = client.discover(peer)
  let assert Some(client.ServerInfo("relay-test", "1.2.3")) =
    discovery.server_info
  let assert Some("Call echo.") = discovery.instructions
  let assert True = list.contains(discovery.supported_versions, "2026-07-28")
  let assert True = client.has_capability(discovery, "tools")
  let assert False = client.has_capability(discovery, "no-such-capability")
  client.close(peer)
}

pub fn discover_without_2026_07_28_is_unsupported_version_test() {
  let assert Ok(peer) =
    client.connect(answering_peer(
      "{\"supportedVersions\":[\"2025-11-25\"],\"capabilities\":{}}",
    ))
  let assert Error(client.UnsupportedVersion(["2025-11-25"])) =
    client.discover(peer)
  client.close(peer)
}

pub fn http_client_uses_explicit_ca_for_tls_test() {
  let assert Ok(handler) =
    http.start(
      http.new(local_server(process.new_subject()))
      |> http.with_tls(
        "test/fixtures/tls/localhost.crt",
        "test/fixtures/tls/localhost.key",
      ),
    )
  let url = "https://localhost:" <> int.to_string(http.port(handler)) <> "/"
  let assert Ok(config) = client.http(url)
  let assert Ok(untrusted) = client.connect(config)
  let assert Error(_) = client.discover(untrusted)
  client.close(untrusted)
  let assert Ok(trusted) =
    config
    |> client.with_ca_cert_file("test/fixtures/tls/root-ca.crt")
    |> client.connect
  let assert Ok(discovery) = client.discover(trusted)
  let assert True = list.contains(discovery.supported_versions, "2026-07-28")
  client.close(trusted)
  http.stop(handler)
}

// --- listening ---------------------------------------------------------------

pub fn http_subscription_receives_requested_list_change_test() {
  let watched =
    resources.static("memory://watched", "watched", fn(_context, uri) {
      Ok([content.text_resource(uri, "watched")])
    })
  let #(handler, url) =
    start_http(server.new([]) |> server.with_resources([watched]))
  let peer = connect_url(url)

  // A raw client that disconnects after the first event.
  let raw_body =
    json.object([
      #("jsonrpc", json.string("2.0")),
      #("id", json.string("raw-subscription-probe")),
      #("method", json.string("subscriptions/listen")),
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
          #(
            "notifications",
            json.object([#("toolsListChanged", json.bool(True))]),
          ),
        ]),
      ),
    ])
    |> json.to_string
  let assert Ok(200) =
    disconnect_after_first_sse_event(
      http.port(handler),
      "POST",
      [
        #("Accept", "text/event-stream"),
        #("MCP-Protocol-Version", "2026-07-28"),
        #("Mcp-Method", "subscriptions/listen"),
      ],
      <<raw_body:utf8>>,
    )

  let assert Ok(subscription) =
    client.listen(peer, [
      subscriptions.ToolsListChanged,
      subscriptions.ResourceUpdated("memory://watched"),
    ])
  let assert True =
    list.contains(
      client.listening(subscription),
      subscriptions.ToolsListChanged,
    )
  let assert True =
    list.contains(
      client.listening(subscription),
      subscriptions.ResourceUpdated("memory://watched"),
    )
  // Nothing yet.
  let assert Ok(None) =
    client.next_notification(subscription, duration.milliseconds(100))

  let late =
    tool.define("late-bound", named_input(), codec.string())
    |> tool.with_description("Registered after HTTP listener startup")
  let assert Ok(Nil) =
    http.register_tool(handler, late |> tool.handle(fn(_) { Ok("arrived") }))
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(subscription, duration.seconds(1))

  let other = connect_url(url)
  let assert Ok(listed) = client.list_tools(other)
  let assert True =
    list.any(listed, fn(declaration) {
      declaration.name == "late-bound"
      && declaration.description
      == Some("Registered after HTTP listener startup")
    })
  let assert Ok(client.Succeeded("arrived", _)) =
    client.call(other, late, "caller")

  http.notify(handler, subscriptions.ResourceUpdated("memory://watched"))
  let assert Ok(Some(subscriptions.ResourceUpdated("memory://watched"))) =
    client.next_notification(subscription, duration.seconds(1))

  let assert True = http.unregister_tool(handler, "late-bound")
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(subscription, duration.seconds(1))
  let assert Ok(after_removal) = client.list_tools(other)
  let assert False =
    list.any(after_removal, fn(declaration) { declaration.name == "late-bound" })

  client.close(other)
  client.close_subscription(subscription)
  client.close(peer)
  http.stop(handler)
}

pub fn http_subscription_from_empty_registry_honors_first_tool_change_test() {
  assert_subscription_reconciles_tool_change(server.new([]), "first-tool")
}

pub fn http_subscription_reconciles_change_during_establishment_test() {
  assert_subscription_reconciles_tool_change(
    local_server(process.new_subject()),
    "racing-tool",
  )
}

// Starts a worker that runs `change` while the first request's context is
// being built, then releases that request and every later one.
fn gated_context(
  change: fn(http.Handler(Nil)) -> a,
) -> #(fn(http.Handler(Nil)) -> Nil, fn() -> Nil, Subject(a)) {
  let worker_ready = process.new_subject()
  let changed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let start = process.new_subject()
      process.send(worker_ready, #(command, start))
      let assert Ok(handler) = process.receive(command, within: 3000)
      let assert Ok(release) = process.receive(start, within: 3000)
      process.send(changed, change(handler))
      process.send(release, Nil)
      context_gate(start)
    })
  let assert Ok(#(command, start)) = process.receive(worker_ready, within: 3000)
  let context = fn() {
    let released = process.new_subject()
    process.send(start, released)
    let _ = process.receive(released, within: 3000)
    Nil
  }
  #(fn(handler) { process.send(command, handler) }, context, changed)
}

fn context_gate(start: Subject(Subject(Nil))) -> Nil {
  case process.receive(start, within: 3000) {
    Ok(release) -> {
      process.send(release, Nil)
      context_gate(start)
    }
    Error(_) -> Nil
  }
}

fn start_gated(
  service: server.Server(Nil),
  context: fn() -> Nil,
) -> http.Handler(Nil) {
  let assert Ok(handler) =
    http.start(
      http.new_with_context(service, fn(_request) {
        context()
        Ok(Nil)
      }),
    )
  handler
}

fn assert_subscription_reconciles_tool_change(
  initial: server.Server(Nil),
  late_name: String,
) -> Nil {
  let late =
    tool.define(late_name, named_input(), codec.string())
    |> tool.with_description("Registered during subscription establishment")
    |> tool.handle(fn(_) { Ok("arrived") })
  let #(arm, context, changed) =
    gated_context(fn(handler) { http.register_tool(handler, late) })
  let handler = start_gated(initial, context)
  arm(handler)
  let peer = connect_url(url_of(handler))
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert Ok(Ok(Nil)) = process.receive(changed, within: 3000)
  let assert [subscriptions.ToolsListChanged] = client.listening(subscription)
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(subscription, duration.seconds(1))
  let other = connect_url(url_of(handler))
  let assert Ok(listed) = client.list_tools(other)
  let assert True =
    list.any(listed, fn(declaration) { declaration.name == late_name })
  client.close(other)
  client.close_subscription(subscription)
  client.close(peer)
  http.stop(handler)
}

pub fn http_subscription_reconciles_same_name_replacement_during_establishment_test() {
  let definition = tool.define("replace-me", named_input(), codec.string())
  let old =
    definition
    |> tool.with_description("old metadata")
    |> tool.handle(fn(_) { Ok("old handler") })
  let replacement =
    definition
    |> tool.with_description("replacement metadata")
    |> tool.handle(fn(_) { Ok("replacement handler") })
  let #(arm, context, changed) =
    gated_context(fn(handler) {
      let removed = http.unregister_tool(handler, "replace-me")
      let registered = http.register_tool(handler, replacement)
      #(removed, registered)
    })
  let handler = start_gated(server.new([old]), context)
  arm(handler)
  let peer = connect_url(url_of(handler))
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert Ok(#(True, Ok(Nil))) = process.receive(changed, within: 3000)
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(subscription, duration.seconds(1))
  let other = connect_url(url_of(handler))
  let assert Ok([listed]) = client.list_tools(other)
  let assert Some("replacement metadata") = listed.description
  let assert Ok(client.Succeeded("replacement handler", _)) =
    client.call(other, definition, "replacement caller")
  client.close(other)
  client.close_subscription(subscription)
  client.close(peer)
  http.stop(handler)
}

pub fn http_subscription_after_registry_churn_reconciles_current_state_test() {
  let #(handler, url) = start_http(server.new([]))
  churn(handler, 128)
  let peer = connect_url(url)
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert [subscriptions.ToolsListChanged] = client.listening(subscription)
  client.close_subscription(subscription)
  client.close(peer)
  http.stop(handler)
}

fn churn(handler: http.Handler(Nil), remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let name = "churn-" <> int.to_string(remaining)
      let assert Ok(Nil) =
        http.register_tool(
          handler,
          tool.define(name, named_input(), codec.string()) |> tool.handle(Ok),
        )
      let assert True = http.unregister_tool(handler, name)
      churn(handler, remaining - 1)
    }
  }
}

pub fn http_subscription_fails_when_the_endpoint_stops_test() {
  let entered = process.new_subject()
  let assert Ok(handler) =
    http.start(
      http.new_with_context(server.new([]), fn(_request) {
        let release = process.new_subject()
        process.send(entered, release)
        let _ = process.receive(release, within: 3000)
        Ok(Nil)
      })
      |> http.with_request_timeout(duration.seconds(1)),
    )
  let peer = connect_url(url_of(handler))
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        result,
        client.listen(peer, [subscriptions.ToolsListChanged]),
      )
    })
  let assert Ok(release) = process.receive(entered, within: 3000)
  http.stop(handler)
  process.send(release, Nil)
  let assert Ok(Error(_)) = process.receive(result, within: 5000)
  client.close(peer)
}

// --- stdio -------------------------------------------------------------------

pub fn stdio_client_uses_typed_request_surface_test() {
  let peer = connect_runner()
  let assert Ok(discovery) = client.discover(peer)
  let assert True = list.contains(discovery.supported_versions, "2026-07-28")
  let greet = tool.define("greet", named_input(), codec.string())
  let assert Ok(client.Succeeded("child-server: hello stdio", [block])) =
    client.call(peer, greet, "stdio")
  let assert True = block == content.text("child-server: hello stdio")
  client.close(peer)
}

pub fn stdio_client_redacts_its_command_test() {
  let config = client.stdio("/usr/local/bin/secret-server", ["secret-token"])
  let printed = string.inspect(config)
  let assert False = string.contains(printed, "secret-server")
  let assert False = string.contains(printed, "secret-token")
  let assert Ok(peer) =
    client.stdio("./test/fixtures/stdio/relay-stdio", ["secret-token"])
    |> client.connect
  let printed = string.inspect(peer)
  let assert False = string.contains(printed, "relay-stdio")
  let assert False = string.contains(printed, "secret-token")
  client.close(peer)
}

pub fn stdio_client_rejects_unrelated_responses_test() {
  let assert Ok(peer) =
    client.stdio("/bin/sh", [
      "-c",
      "IFS= read -r request; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"uri\":\"file:///ignored\"}}'; printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":\"wrong-id\",\"result\":{}}'",
    ])
    |> client.connect
  let assert Error(client.MalformedResponse(_)) = client.discover(peer)
  client.close(peer)
}

pub fn stdio_client_subscriptions_retain_ack_and_notifications_test() {
  let assert Ok(peer) =
    client.stdio("./test/fixtures/stdio/subscription-peer", [])
    |> client.connect
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert [subscriptions.ToolsListChanged] = client.listening(subscription)
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(subscription, duration.seconds(1))
  client.close_subscription(subscription)
  client.close(peer)
}

pub fn stdio_listen_on_a_relay_server_test() {
  let peer = connect_runner()
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert [subscriptions.ToolsListChanged] = client.listening(subscription)
  let assert Ok(None) =
    client.next_notification(subscription, duration.milliseconds(100))
  // The stream stays open; other requests continue.
  let assert Ok(_) = client.discover(peer)
  client.close_subscription(subscription)
  client.close(peer)
}

pub fn stdio_client_preserves_frozen_declaration_fields_test() {
  let assert Ok(peer) =
    client.stdio("./test/fixtures/stdio/declaration-peer", [])
    |> client.connect
  let assert Ok([declared]) = client.list_tools(peer)
  let assert Ok([resource]) = client.list_resources(peer)
  let assert Ok([template]) = client.list_resource_templates(peer)
  let assert Ok([prompt]) = client.list_prompts(peer)
  client.close(peer)

  let assert "annotated" = declared.name
  let assert Some("Annotated tool") = declared.title
  let assert tool.ToolAnnotations(
    Some("Safe lookup"),
    Some(True),
    Some(False),
    Some(True),
    Some(False),
  ) = declared.annotations
  let assert [
    content.Icon(
      "https://example.test/tool.svg",
      Some("image/svg+xml"),
      ["any"],
      Some(content.DarkTheme),
    ),
  ] = declared.icons
  let assert Some(value.Object([#("type", value.String("string"))])) =
    declared.output_schema
  let assert [#("vendor", value.String("fixture"))] = declared.meta

  let assert Some(content.Annotations(
    [content.UserRole],
    Some(0.5),
    Some("2026-09-22T00:00:00Z"),
  )) = resource.annotations
  let assert [content.Icon(_, None, ["48x48"], Some(content.LightTheme))] =
    resource.icons
  let assert Some(12) = resource.size

  let assert "memory://annotated/{name}" = template.uri_template
  let assert [_] = template.icons
  let assert [] = prompt.arguments
  let assert [content.Icon(_, None, [], Some(content.DarkTheme))] = prompt.icons
}

pub fn stdio_subscription_is_ordered_cancellable_and_timeout_safe_test() {
  let assert Ok(peer) =
    client.stdio("./test/fixtures/stdio/subscription-lifecycle-peer", [])
    |> client.connect
  let requested = [
    subscriptions.ToolsListChanged,
    subscriptions.PromptsListChanged,
  ]
  let assert Ok(first) = client.listen(peer, requested)
  let assert Ok(second) = client.listen(peer, requested)

  let assert Ok(None) =
    client.next_notification(first, duration.milliseconds(300))
  let assert Ok(Some(subscriptions.ToolsListChanged)) =
    client.next_notification(second, duration.seconds(1))
  let assert Ok(Some(subscriptions.PromptsListChanged)) =
    client.next_notification(second, duration.seconds(1))

  // Closing tells the peer, which only then answers discovery.
  client.close_subscription(second)
  let assert Ok(discovery) = client.discover(peer)
  let assert Some(client.ServerInfo("lifecycle-peer", "1")) =
    discovery.server_info
  let assert Error(_) =
    client.next_notification(second, duration.milliseconds(100))
  client.close_subscription(first)
  client.close(peer)
}

pub fn stdio_frame_overflow_closes_the_owned_child_test() {
  let assert Ok(peer) =
    client.stdio("./test/fixtures/stdio/overflow-peer", [])
    |> client.connect
  let assert Error(client.MalformedResponse(_)) = client.discover(peer)
  let assert Error(client.ConnectionClosed(client.NotSent)) =
    client.discover(peer)
  client.close(peer)
}

pub fn stdio_client_handles_child_exit_and_repeated_close_test() {
  let assert Ok(peer) =
    client.stdio("/bin/sh", ["-c", "exit 3"]) |> client.connect
  let assert Error(_) = client.discover(peer)
  client.close(peer)
  client.close(peer)
}

pub fn stdio_child_exit_mid_call_is_connection_closed_test() {
  let assert Ok(peer) =
    client.stdio("/bin/sh", ["-c", "IFS= read -r request; exit 0"])
    |> client.connect
  let assert Error(client.ConnectionClosed(client.MaybeSent)) =
    client.discover(peer)
  client.close(peer)
}

pub fn stdio_timeout_is_timed_out_test() {
  let assert Ok(peer) =
    runner_config()
    |> client.with_timeout(duration.milliseconds(300))
    |> client.connect
  let started = monotonic_ms()
  let assert Error(client.TimedOut(client.MaybeSent)) =
    client.call(peer, runner_property_definition("slow", "ms"), 2000)
  let assert True = monotonic_ms() - started < 1800
  client.close(peer)
}

pub fn stdio_pending_call_limit_test() {
  let assert Ok(peer) =
    runner_config()
    |> client.with_max_pending_calls(1)
    |> client.connect
  // Wait until the child answers before loading it.
  let assert Ok(_) = client.discover(peer)
  let slow = runner_property_definition("slow", "ms")
  let results = process.new_subject()
  // One call in flight for 600 ms, one waiting behind it, then two more
  // beyond the limit while both still wait.
  list.each([1, 2, 3, 4], fn(index) {
    let _ =
      process.spawn(fn() {
        process.send(results, #(index, client.call(peer, slow, 600)))
      })
    process.sleep(60)
  })
  let outcomes =
    list.map([1, 2, 3, 4], fn(_) {
      let assert Ok(outcome) = process.receive(results, 5000)
      outcome
    })
    |> list.sort(fn(left, right) { int.compare(left.0, right.0) })
  let assert [
    #(1, Ok(client.Succeeded("slow response", _))),
    #(2, Ok(client.Succeeded("slow response", _))),
    #(3, Error(client.TooManyPendingCalls(1))),
    #(4, Error(client.TooManyPendingCalls(1))),
  ] = outcomes
  client.close(peer)
}

pub fn stdio_client_concurrent_close_is_safe_test() {
  let peer = connect_runner()
  let finished = process.new_subject()
  let _ =
    process.spawn(fn() {
      client.close(peer)
      process.send(finished, Nil)
    })
  let _ =
    process.spawn(fn() {
      client.close(peer)
      process.send(finished, Nil)
    })
  let assert Ok(Nil) = process.receive(finished, within: 3000)
  let assert Ok(Nil) = process.receive(finished, within: 3000)
}

pub fn stdio_tool_call_close_is_typed_cancellation_test() {
  let peer = input_peer([])
  let definition = tool.define("slow", codec.success(Nil), codec.string())
  let done = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.send(done, client.call(peer, definition, Nil))
    })
  process.sleep(100)
  client.close(peer)
  let assert Ok(Error(client.Cancelled(client.MaybeSent))) =
    process.receive(done, within: 3000)
}

// --- relay/testing -----------------------------------------------------------

pub fn testing_connect_serves_every_operation_test() {
  let peer = testing.connect(local_server(process.new_subject()), Nil)
  let assert Ok(client.Succeeded("hello in-process", _)) =
    client.call(peer, echo_definition(), "in-process")
  let assert Ok(tools) = client.list_tools(peer)
  let assert 108 = list.length(tools)
  let assert Ok([content.TextResourceContents(_, "template resource", _, _)]) =
    client.read_resource(peer, "memory://client/ada")
  let assert Ok(prompts.PromptResult(Some("client prompt"), [_], _)) =
    client.get_prompt(peer, "client-prompt", dict.new())
  let assert Ok(completion.Values(["ad-next"], _, _)) =
    client.complete(
      peer,
      completion.Request(
        completion.ResourceReference("memory://client/{name}"),
        "name",
        "ad",
        dict.from_list([#("other", "known")]),
      ),
    )
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let assert [subscriptions.ToolsListChanged] = client.listening(subscription)
  let assert Ok(None) =
    client.next_notification(subscription, duration.milliseconds(100))
  client.close_subscription(subscription)
  client.close(peer)
}
