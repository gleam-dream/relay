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
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use reason <- fields.include(fields.string("reason"), get: fn(m) {
      m.reason
    })
    fields.success(FrameRejectedMeta(exchange_id:, reason:))
  }
  sinal.event(["relay", "frame", "rejected"], fields.empty(), meta)
}

pub fn request_admitted_event() -> Event(Nil, RequestAdmittedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    fields.success(RequestAdmittedMeta(exchange_id:, method:))
  }
  sinal.event(["relay", "request", "admitted"], fields.empty(), meta)
}

pub fn invocation_started_event() -> Event(Nil, InvocationStartedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use tool_name <- fields.include(fields.string("tool_name"), get: fn(m) {
      m.tool_name
    })
    fields.success(InvocationStartedMeta(
      exchange_id:,
      invocation_id:,
      tool_name:,
    ))
  }
  sinal.event(["relay", "invocation", "started"], fields.empty(), meta)
}

pub fn invocation_completed_event() -> Event(
  InvocationCompletedMeasurements,
  InvocationCompletedMeta,
) {
  let measurements = {
    use duration_ms <- fields.include(fields.int("duration_ms"), get: fn(m) {
      m.duration_ms
    })
    fields.success(InvocationCompletedMeasurements(duration_ms))
  }
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use status <- fields.include(fields.string("status"), get: fn(m) {
      m.status
    })
    fields.success(InvocationCompletedMeta(
      exchange_id:,
      invocation_id:,
      status:,
    ))
  }
  sinal.event(["relay", "invocation", "completed"], measurements, meta)
}

pub fn invocation_cancelled_event() -> Event(Nil, InvocationCancelledMeta) {
  let meta = {
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    fields.success(InvocationCancelledMeta(invocation_id))
  }
  sinal.event(["relay", "invocation", "cancelled"], fields.empty(), meta)
}

pub fn invocation_crashed_event() -> Event(Nil, InvocationCrashedMeta) {
  let meta = {
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use reason <- fields.include(fields.string("reason"), get: fn(m) {
      m.reason
    })
    fields.success(InvocationCrashedMeta(invocation_id:, reason:))
  }
  sinal.event(["relay", "invocation", "crashed"], fields.empty(), meta)
}

pub fn exchange_closed_event() -> Event(Nil, ExchangeClosedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    fields.success(ExchangeClosedMeta(exchange_id))
  }
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
