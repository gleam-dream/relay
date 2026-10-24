import gleam/dict
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import json/blueprint/value
import relay/client
import relay/http
import relay/subscriptions
import relay/testing
import relay_conformance_server as fixture

fn elicitation(peer: client.Client, responses: json.Json) -> String {
  let assert Ok(value.Object(fields)) =
    client.call_raw(
      peer,
      "tools/call",
      Some("test_input_required_result_elicitation"),
      [
        #("name", json.string("test_input_required_result_elicitation")),
        #("arguments", json.object([])),
        #("inputResponses", responses),
      ],
    )
  let assert Ok(value.String(kind)) =
    dict.get(dict.from_list(fields), "resultType")
  kind
}

fn accepted_name() -> json.Json {
  json.object([
    #("action", json.string("accept")),
    #("content", json.object([#("name", json.string("Ada"))])),
  ])
}

pub fn fixture_rerequests_missing_and_malformed_elicitation_responses_test() {
  let peer = testing.connect(fixture.conformance_server(), Nil)
  list.each(
    [
      json.object([#("wrong_key", accepted_name())]),
      json.object([#("user_name", json.int(12_345))]),
      json.object([#("user_name", json.object([]))]),
      json.object([
        #(
          "user_name",
          json.object([
            #("action", json.string("accept")),
            #("content", json.object([#("name", json.int(3))])),
          ]),
        ),
      ]),
    ],
    fn(responses) {
      elicitation(peer, responses) |> should.equal("input_required")
    },
  )
  client.close(peer)
}

pub fn fixture_accepts_requested_typed_response_and_ignores_extra_keys_test() {
  let peer = testing.connect(fixture.conformance_server(), Nil)
  elicitation(
    peer,
    json.object([#("user_name", accepted_name()), #("unrelated", json.int(123))]),
  )
  |> should.equal("complete")
  client.close(peer)
}

fn trigger(peer: client.Client, name: String) -> Nil {
  let assert Ok(_) =
    client.call_raw(peer, "tools/call", Some(name), [
      #("name", json.string(name)),
      #("arguments", json.object([])),
    ])
  Nil
}

pub fn fixture_diagnostics_mutate_tool_catalog_and_notify_prompt_stream_test() {
  let handler = fixture.start()
  let assert Ok(config) =
    client.http(
      "http://127.0.0.1:" <> int.to_string(http.port(handler)) <> "/mcp",
    )
  let assert Ok(peer) = client.connect(config)
  let assert Ok(stream) =
    client.listen(peer, [
      subscriptions.ToolsListChanged,
      subscriptions.PromptsListChanged,
    ])
  trigger(peer, "test_trigger_tool_change")
  client.next_notification(stream, duration.seconds(1))
  |> should.equal(Ok(Some(subscriptions.ToolsListChanged)))
  let assert Ok(tools) = client.list_tools(peer)
  list.any(tools, fn(tool) { tool.name == "conformance_added_tool" })
  |> should.be_true
  trigger(peer, "test_trigger_prompt_change")
  client.next_notification(stream, duration.seconds(1))
  |> should.equal(Ok(Some(subscriptions.PromptsListChanged)))
  client.close_subscription(stream)
  client.close(peer)
  http.stop(handler)
}
