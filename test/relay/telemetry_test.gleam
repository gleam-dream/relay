import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import relay/internal/emit
import relay/telemetry
import sinal
import sinal/correlation

/// Forwards every event whose `listener` (or other label field) equals
/// `label`, so other emitters cannot interfere.
fn capture(
  event: sinal.Event(m, d),
  label: String,
  listener: fn(d) -> Option(String),
) -> #(sinal.Attachment, Subject(#(m, d))) {
  let events = process.new_subject()
  let attachment =
    sinal.observe(event, fn(measured, meta) {
      case listener(meta) == Some(label) {
        True -> process.send(events, #(measured, meta))
        False -> Nil
      }
    })
  #(attachment, events)
}

fn received(events: Subject(#(m, d))) -> #(m, d) {
  let assert Ok(event) = process.receive(events, 500)
  event
}

pub fn event_names_test() {
  sinal.name(telemetry.frame_rejected_event())
  |> should.equal(["relay", "frame", "rejected"])
  sinal.name(telemetry.request_admitted_event())
  |> should.equal(["relay", "request", "admitted"])
  sinal.name(telemetry.invocation_started_event())
  |> should.equal(["relay", "invocation", "started"])
  sinal.name(telemetry.invocation_completed_event())
  |> should.equal(["relay", "invocation", "completed"])
  sinal.name(telemetry.invocation_cancelled_event())
  |> should.equal(["relay", "invocation", "cancelled"])
  sinal.name(telemetry.invocation_crashed_event())
  |> should.equal(["relay", "invocation", "crashed"])
  sinal.name(telemetry.exchange_closed_event())
  |> should.equal(["relay", "exchange", "closed"])
  sinal.name(telemetry.http_rejected_event())
  |> should.equal(["relay", "http", "rejected"])
  sinal.name(telemetry.authorization_decided_event())
  |> should.equal(["relay", "authorization", "decided"])
  sinal.name(telemetry.client_call_event())
  |> should.equal(["relay", "client", "call"])
}

pub fn frame_rejected_observation_test() {
  let label = "tel-frame"
  let #(attachment, events) =
    capture(telemetry.frame_rejected_event(), label, fn(m) { m.listener })

  [
    telemetry.FrameTooLarge,
    telemetry.TooManyExchanges,
    telemetry.NestingTooDeep,
    telemetry.TrailingBytes,
  ]
  |> list.each(fn(problem) {
    emit.frame_rejected(42, problem, Some(label))
    received(events).1
    |> should.equal(telemetry.FrameRejectedMeta(
      exchange_id: 42,
      problem: problem,
      listener: Some(label),
    ))
  })

  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn request_admitted_observation_test() {
  let label = "tel-admitted"
  let #(attachment, events) =
    capture(telemetry.request_admitted_event(), label, fn(m) { m.listener })
  let corr = correlation.from_key("tel-admitted-correlation")

  emit.request_admitted(99, "server/discover", Some(corr), Some(label))
  received(events).1
  |> should.equal(telemetry.RequestAdmittedMeta(
    exchange_id: 99,
    method: "server/discover",
    correlation: Some(corr),
    listener: Some(label),
  ))

  emit.request_admitted(100, "tools/list", None, Some(label))
  let meta = received(events).1
  meta.method |> should.equal("tools/list")
  meta.correlation |> should.equal(None)

  let assert Ok(Nil) = sinal.detach(attachment)
}

pub fn invocation_lifecycle_observation_test() {
  let label = "tel-lifecycle"
  let #(started_attachment, started_events) =
    capture(telemetry.invocation_started_event(), label, fn(m) { m.listener })
  let #(completed_attachment, completed_events) =
    capture(telemetry.invocation_completed_event(), label, fn(m) { m.listener })
  let corr = correlation.unique()

  let started =
    telemetry.InvocationStartedMeta(
      exchange_id: 1,
      invocation_id: 10,
      method: "tools/call",
      tool: Some("greet"),
      correlation: Some(corr),
      listener: Some(label),
    )
  emit.invocation_started(started)
  received(started_events).1 |> should.equal(started)

  [
    telemetry.Succeeded,
    telemetry.ToolFailed,
    telemetry.InputRequested,
    telemetry.Failed,
  ]
  |> list.each(fn(status) {
    let completed =
      telemetry.InvocationCompletedMeta(
        exchange_id: 1,
        invocation_id: 10,
        method: "tools/call",
        tool: Some("greet"),
        status: status,
        correlation: Some(corr),
        listener: Some(label),
      )
    emit.invocation_completed(25, completed)
    let #(measured, meta) = received(completed_events)
    measured.duration_ms |> should.equal(25)
    meta |> should.equal(completed)
  })

  // A non-tool invocation carries no tool name.
  let read =
    telemetry.InvocationStartedMeta(
      exchange_id: 2,
      invocation_id: 11,
      method: "resources/read",
      tool: None,
      correlation: None,
      listener: Some(label),
    )
  emit.invocation_started(read)
  received(started_events).1 |> should.equal(read)

  let assert Ok(Nil) = sinal.detach(started_attachment)
  let assert Ok(Nil) = sinal.detach(completed_attachment)
}

pub fn crash_and_cancel_observation_test() {
  let label = "tel-crash"
  let #(cancel_attachment, cancel_events) =
    capture(telemetry.invocation_cancelled_event(), label, fn(m) { m.listener })
  let #(crash_attachment, crash_events) =
    capture(telemetry.invocation_crashed_event(), label, fn(m) { m.listener })
  let #(close_attachment, close_events) =
    capture(telemetry.exchange_closed_event(), label, fn(m) { m.listener })

  let cancelled =
    telemetry.InvocationCancelledMeta(
      invocation_id: 55,
      method: "tools/call",
      tool: Some("slow"),
      correlation: None,
      listener: Some(label),
    )
  emit.invocation_cancelled(cancelled)
  received(cancel_events).1 |> should.equal(cancelled)

  [telemetry.HandlerCrashed, telemetry.HandlerTimedOut]
  |> list.each(fn(reason) {
    let crashed =
      telemetry.InvocationCrashedMeta(
        invocation_id: 55,
        method: "tools/call",
        tool: Some("slow"),
        reason: reason,
        correlation: None,
        listener: Some(label),
      )
    emit.invocation_crashed(crashed)
    received(crash_events).1 |> should.equal(crashed)
  })

  emit.exchange_closed(101, Some(label))
  received(close_events).1
  |> should.equal(telemetry.ExchangeClosedMeta(
    exchange_id: 101,
    listener: Some(label),
  ))

  let assert Ok(Nil) = sinal.detach(cancel_attachment)
  let assert Ok(Nil) = sinal.detach(crash_attachment)
  let assert Ok(Nil) = sinal.detach(close_attachment)
}

pub fn http_and_authorization_observation_test() {
  let label = "tel-http"
  let #(http_attachment, http_events) =
    capture(telemetry.http_rejected_event(), label, fn(m) { m.listener })
  let #(auth_attachment, auth_events) =
    capture(telemetry.authorization_decided_event(), label, fn(m) { m.listener })
  let corr = correlation.from_key("tel-http-correlation")

  [
    telemetry.HostNotAllowed,
    telemetry.OriginNotAllowed,
    telemetry.MethodNotAllowed,
    telemetry.UnsupportedMediaType,
    telemetry.NotAcceptable,
    telemetry.BodyTooLarge,
    telemetry.MalformedBody,
    telemetry.RoutingHeaderMismatch,
    telemetry.TooManyRequests,
    telemetry.TooManyStreams,
    telemetry.Unauthenticated,
  ]
  |> list.each(fn(reason) {
    emit.http_rejected(403, reason, Some(corr), Some(label))
    received(http_events).1
    |> should.equal(telemetry.HttpRejectedMeta(
      status: 403,
      reason: reason,
      correlation: Some(corr),
      listener: Some(label),
    ))
  })

  [
    telemetry.Granted,
    telemetry.MissingToken,
    telemetry.InvalidToken,
    telemetry.VerifierUnavailable,
    telemetry.WrongResource,
    telemetry.InsufficientScope,
  ]
  |> list.each(fn(decision) {
    emit.authorization_decided("test-verifier", decision, None, Some(label))
    received(auth_events).1
    |> should.equal(telemetry.AuthorizationDecidedMeta(
      verifier: "test-verifier",
      decision: decision,
      correlation: None,
      listener: Some(label),
    ))
  })

  let assert Ok(Nil) = sinal.detach(http_attachment)
  let assert Ok(Nil) = sinal.detach(auth_attachment)
}

pub fn client_call_observation_test() {
  let label = "tel-client"
  let #(attachment, events) =
    capture(telemetry.client_call_event(), label, fn(m) { m.client })

  [
    telemetry.CallCompleted,
    telemetry.CallToolFailed,
    telemetry.CallInputRequired,
    telemetry.CallFailed,
  ]
  |> list.each(fn(outcome) {
    let meta =
      telemetry.ClientCallMeta(
        method: "tools/call",
        tool: Some("greet"),
        outcome: outcome,
        correlation: None,
        client: Some(label),
      )
    emit.client_call(7, meta)
    let #(measured, observed) = received(events)
    measured.duration_ms |> should.equal(7)
    observed |> should.equal(meta)
  })

  let assert Ok(Nil) = sinal.detach(attachment)
}
