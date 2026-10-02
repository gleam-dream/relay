//// Sinal telemetry events that Relay's runtime emits.
////
//// The events are `[relay, frame, rejected]`, `[relay, request, admitted]`,
//// `[relay, invocation, started]`, `[relay, invocation, completed]`,
//// `[relay, invocation, cancelled]`, `[relay, invocation, crashed]` and
//// `[relay, exchange, closed]`. Each `*_event` function returns the
//// `sinal.Event` descriptor that a handler attaches to. The `emit_*` functions
//// are what `relay/runtime` calls; they ignore emission failures. Metadata
//// holds exchange and invocation ids, the request method, and a reason string
//// for rejections and crashes.

import gleam/erlang/atom
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
  let ev_name = [
    atom.create("relay"),
    atom.create("frame"),
    atom.create("rejected"),
  ]
  let assert Ok(meta_pair) =
    fields.pair(
      fields.int(atom.create("exchange_id")),
      fields.string(atom.create("reason")),
    )
  let meta =
    fields.imap(
      meta_pair,
      fn(pair) { FrameRejectedMeta(pair.0, pair.1) },
      fn(m) { #(m.exchange_id, m.reason) },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

pub fn request_admitted_event() -> Event(Nil, RequestAdmittedMeta) {
  let ev_name = [
    atom.create("relay"),
    atom.create("request"),
    atom.create("admitted"),
  ]
  let assert Ok(meta_pair) =
    fields.pair(
      fields.int(atom.create("exchange_id")),
      fields.string(atom.create("method")),
    )
  let meta =
    fields.imap(
      meta_pair,
      fn(pair) { RequestAdmittedMeta(pair.0, pair.1) },
      fn(m) { #(m.exchange_id, m.method) },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

pub fn invocation_started_event() -> Event(Nil, InvocationStartedMeta) {
  let ev_name = [
    atom.create("relay"),
    atom.create("invocation"),
    atom.create("started"),
  ]
  let assert Ok(p1) =
    fields.pair(
      fields.int(atom.create("exchange_id")),
      fields.int(atom.create("invocation_id")),
    )
  let assert Ok(p2) = fields.pair(p1, fields.string(atom.create("tool_name")))
  let meta =
    fields.imap(
      p2,
      fn(pair) {
        let #(#(ex, inv), tool) = pair
        InvocationStartedMeta(ex, inv, tool)
      },
      fn(m) { #(#(m.exchange_id, m.invocation_id), m.tool_name) },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

pub fn invocation_completed_event() -> Event(
  InvocationCompletedMeasurements,
  InvocationCompletedMeta,
) {
  let ev_name = [
    atom.create("relay"),
    atom.create("invocation"),
    atom.create("completed"),
  ]
  let meas =
    fields.imap(
      fields.int(atom.create("duration_ms")),
      fn(d) { InvocationCompletedMeasurements(d) },
      fn(m) { m.duration_ms },
    )
  let assert Ok(p1) =
    fields.pair(
      fields.int(atom.create("exchange_id")),
      fields.int(atom.create("invocation_id")),
    )
  let assert Ok(p2) = fields.pair(p1, fields.string(atom.create("status")))
  let meta =
    fields.imap(
      p2,
      fn(pair) {
        let #(#(ex, inv), st) = pair
        InvocationCompletedMeta(ex, inv, st)
      },
      fn(m) { #(#(m.exchange_id, m.invocation_id), m.status) },
    )
  let assert Ok(ev) = sinal.event(ev_name, meas, meta)
  ev
}

pub fn invocation_cancelled_event() -> Event(Nil, InvocationCancelledMeta) {
  let ev_name = [
    atom.create("relay"),
    atom.create("invocation"),
    atom.create("cancelled"),
  ]
  let meta =
    fields.imap(
      fields.int(atom.create("invocation_id")),
      fn(id) { InvocationCancelledMeta(id) },
      fn(m) { m.invocation_id },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

pub fn invocation_crashed_event() -> Event(Nil, InvocationCrashedMeta) {
  let ev_name = [
    atom.create("relay"),
    atom.create("invocation"),
    atom.create("crashed"),
  ]
  let assert Ok(meta_pair) =
    fields.pair(
      fields.int(atom.create("invocation_id")),
      fields.string(atom.create("reason")),
    )
  let meta =
    fields.imap(
      meta_pair,
      fn(pair) { InvocationCrashedMeta(pair.0, pair.1) },
      fn(m) { #(m.invocation_id, m.reason) },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

pub fn exchange_closed_event() -> Event(Nil, ExchangeClosedMeta) {
  let ev_name = [
    atom.create("relay"),
    atom.create("exchange"),
    atom.create("closed"),
  ]
  let meta =
    fields.imap(
      fields.int(atom.create("exchange_id")),
      fn(id) { ExchangeClosedMeta(id) },
      fn(m) { m.exchange_id },
    )
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), meta)
  ev
}

// Emission helpers (safely catch and ignore any emission failure)

pub fn emit_frame_rejected(exchange_id: Int, reason: String) -> Nil {
  let ev = frame_rejected_event()
  case sinal.emit(ev, Nil, FrameRejectedMeta(exchange_id, reason)) {
    _ -> Nil
  }
}

pub fn emit_request_admitted(exchange_id: Int, method: String) -> Nil {
  let ev = request_admitted_event()
  case sinal.emit(ev, Nil, RequestAdmittedMeta(exchange_id, method)) {
    _ -> Nil
  }
}

pub fn emit_invocation_started(
  exchange_id: Int,
  invocation_id: Int,
  tool_name: String,
) -> Nil {
  let ev = invocation_started_event()
  case
    sinal.emit(
      ev,
      Nil,
      InvocationStartedMeta(exchange_id, invocation_id, tool_name),
    )
  {
    _ -> Nil
  }
}

pub fn emit_invocation_completed(
  exchange_id: Int,
  invocation_id: Int,
  duration_ms: Int,
  status: String,
) -> Nil {
  let ev = invocation_completed_event()
  case
    sinal.emit(
      ev,
      InvocationCompletedMeasurements(duration_ms),
      InvocationCompletedMeta(exchange_id, invocation_id, status),
    )
  {
    _ -> Nil
  }
}

pub fn emit_invocation_cancelled(invocation_id: Int) -> Nil {
  let ev = invocation_cancelled_event()
  case sinal.emit(ev, Nil, InvocationCancelledMeta(invocation_id)) {
    _ -> Nil
  }
}

pub fn emit_invocation_crashed(invocation_id: Int, reason: String) -> Nil {
  let ev = invocation_crashed_event()
  case sinal.emit(ev, Nil, InvocationCrashedMeta(invocation_id, reason)) {
    _ -> Nil
  }
}

pub fn emit_exchange_closed(exchange_id: Int) -> Nil {
  let ev = exchange_closed_event()
  case sinal.emit(ev, Nil, ExchangeClosedMeta(exchange_id)) {
    _ -> Nil
  }
}
