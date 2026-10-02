//// Sinal telemetry events that Relay's runtime emits.
////
//// The events are `[relay, frame, rejected]`, `[relay, request, admitted]`,
//// `[relay, invocation, started]`, `[relay, invocation, completed]`,
//// `[relay, invocation, cancelled]`, `[relay, invocation, crashed]` and
//// `[relay, exchange, closed]`. Each `*_event` function returns the
//// `sinal.Event` descriptor that a handler attaches to. The `emit_*` functions
//// are what `relay/runtime` calls. Metadata
//// holds exchange and invocation ids, the request method, and a reason string
//// for rejections and crashes.

import sinal.{type Event}
import sinal/fields

pub type FrameRejectedMeta {
  FrameRejectedMeta(exchange_id: Int, reason: String)
}

pub type RequestAdmittedMeta {
  RequestAdmittedMeta(exchange_id: Int, method: String)
}

pub type InvocationStartedMeta {
  InvocationStartedMeta(exchange_id: Int, invocation_id: Int, tool_name: String)
}

pub type InvocationCompletedMeasurements {
  InvocationCompletedMeasurements(duration_ms: Int)
}

pub type InvocationCompletedMeta {
  InvocationCompletedMeta(exchange_id: Int, invocation_id: Int, status: String)
}

pub type InvocationCancelledMeta {
  InvocationCancelledMeta(invocation_id: Int)
}

pub type InvocationCrashedMeta {
  InvocationCrashedMeta(invocation_id: Int, reason: String)
}

pub type ExchangeClosedMeta {
  ExchangeClosedMeta(exchange_id: Int)
}

// Descriptors

pub fn frame_rejected_event() -> Event(Nil, FrameRejectedMeta) {
  let meta =
    fields.record({
      use exchange_id <- fields.parameter
      use reason <- fields.parameter
      FrameRejectedMeta(exchange_id:, reason:)
    })
    |> fields.and(fields.int("exchange_id"), fn(m: FrameRejectedMeta) {
      m.exchange_id
    })
    |> fields.and(fields.string("reason"), fn(m) { m.reason })
    |> fields.build
  sinal.event(["relay", "frame", "rejected"], fields.empty(), meta)
}

pub fn request_admitted_event() -> Event(Nil, RequestAdmittedMeta) {
  let meta =
    fields.record({
      use exchange_id <- fields.parameter
      use method <- fields.parameter
      RequestAdmittedMeta(exchange_id:, method:)
    })
    |> fields.and(fields.int("exchange_id"), fn(m: RequestAdmittedMeta) {
      m.exchange_id
    })
    |> fields.and(fields.string("method"), fn(m) { m.method })
    |> fields.build
  sinal.event(["relay", "request", "admitted"], fields.empty(), meta)
}

pub fn invocation_started_event() -> Event(Nil, InvocationStartedMeta) {
  let meta =
    fields.record({
      use exchange_id <- fields.parameter
      use invocation_id <- fields.parameter
      use tool_name <- fields.parameter
      InvocationStartedMeta(exchange_id:, invocation_id:, tool_name:)
    })
    |> fields.and(fields.int("exchange_id"), fn(m: InvocationStartedMeta) {
      m.exchange_id
    })
    |> fields.and(fields.int("invocation_id"), fn(m) { m.invocation_id })
    |> fields.and(fields.string("tool_name"), fn(m) { m.tool_name })
    |> fields.build
  sinal.event(["relay", "invocation", "started"], fields.empty(), meta)
}

pub fn invocation_completed_event() -> Event(
  InvocationCompletedMeasurements,
  InvocationCompletedMeta,
) {
  let measurements =
    fields.record(InvocationCompletedMeasurements)
    |> fields.and(
      fields.int("duration_ms"),
      fn(m: InvocationCompletedMeasurements) { m.duration_ms },
    )
    |> fields.build
  let meta =
    fields.record({
      use exchange_id <- fields.parameter
      use invocation_id <- fields.parameter
      use status <- fields.parameter
      InvocationCompletedMeta(exchange_id:, invocation_id:, status:)
    })
    |> fields.and(fields.int("exchange_id"), fn(m: InvocationCompletedMeta) {
      m.exchange_id
    })
    |> fields.and(fields.int("invocation_id"), fn(m) { m.invocation_id })
    |> fields.and(fields.string("status"), fn(m) { m.status })
    |> fields.build
  sinal.event(["relay", "invocation", "completed"], measurements, meta)
}

pub fn invocation_cancelled_event() -> Event(Nil, InvocationCancelledMeta) {
  let meta =
    fields.record(InvocationCancelledMeta)
    |> fields.and(fields.int("invocation_id"), fn(m: InvocationCancelledMeta) {
      m.invocation_id
    })
    |> fields.build
  sinal.event(["relay", "invocation", "cancelled"], fields.empty(), meta)
}

pub fn invocation_crashed_event() -> Event(Nil, InvocationCrashedMeta) {
  let meta =
    fields.record({
      use invocation_id <- fields.parameter
      use reason <- fields.parameter
      InvocationCrashedMeta(invocation_id:, reason:)
    })
    |> fields.and(fields.int("invocation_id"), fn(m: InvocationCrashedMeta) {
      m.invocation_id
    })
    |> fields.and(fields.string("reason"), fn(m) { m.reason })
    |> fields.build
  sinal.event(["relay", "invocation", "crashed"], fields.empty(), meta)
}

pub fn exchange_closed_event() -> Event(Nil, ExchangeClosedMeta) {
  let meta =
    fields.record(ExchangeClosedMeta)
    |> fields.and(fields.int("exchange_id"), fn(m: ExchangeClosedMeta) {
      m.exchange_id
    })
    |> fields.build
  sinal.event(["relay", "exchange", "closed"], fields.empty(), meta)
}

// Emission helpers

pub fn emit_frame_rejected(exchange_id: Int, reason: String) -> Nil {
  sinal.emit(
    frame_rejected_event(),
    Nil,
    FrameRejectedMeta(exchange_id:, reason:),
  )
}

pub fn emit_request_admitted(exchange_id: Int, method: String) -> Nil {
  sinal.emit(
    request_admitted_event(),
    Nil,
    RequestAdmittedMeta(exchange_id:, method:),
  )
}

pub fn emit_invocation_started(
  exchange_id: Int,
  invocation_id: Int,
  tool_name: String,
) -> Nil {
  sinal.emit(
    invocation_started_event(),
    Nil,
    InvocationStartedMeta(exchange_id:, invocation_id:, tool_name:),
  )
}

pub fn emit_invocation_completed(
  exchange_id: Int,
  invocation_id: Int,
  duration_ms: Int,
  status: String,
) -> Nil {
  sinal.emit(
    invocation_completed_event(),
    InvocationCompletedMeasurements(duration_ms:),
    InvocationCompletedMeta(exchange_id:, invocation_id:, status:),
  )
}

pub fn emit_invocation_cancelled(invocation_id: Int) -> Nil {
  sinal.emit(
    invocation_cancelled_event(),
    Nil,
    InvocationCancelledMeta(invocation_id:),
  )
}

pub fn emit_invocation_crashed(invocation_id: Int, reason: String) -> Nil {
  sinal.emit(
    invocation_crashed_event(),
    Nil,
    InvocationCrashedMeta(invocation_id:, reason:),
  )
}

pub fn emit_exchange_closed(exchange_id: Int) -> Nil {
  sinal.emit(exchange_closed_event(), Nil, ExchangeClosedMeta(exchange_id:))
}
