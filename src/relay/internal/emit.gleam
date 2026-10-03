//// Emission helpers for the events in `relay/telemetry`.

import gleam/option.{type Option}
import relay/telemetry
import sinal
import sinal/correlation.{type Correlation}

pub fn frame_rejected(
  exchange_id: Int,
  problem: telemetry.FrameProblem,
  listener: Option(String),
) -> Nil {
  sinal.emit(
    telemetry.frame_rejected_event(),
    Nil,
    telemetry.FrameRejectedMeta(exchange_id:, problem:, listener:),
  )
}

pub fn request_admitted(
  exchange_id: Int,
  method: String,
  correlation: Option(Correlation),
  listener: Option(String),
) -> Nil {
  sinal.emit(
    telemetry.request_admitted_event(),
    Nil,
    telemetry.RequestAdmittedMeta(
      exchange_id:,
      method:,
      correlation:,
      listener:,
    ),
  )
}

pub fn invocation_started(meta: telemetry.InvocationStartedMeta) -> Nil {
  sinal.emit(telemetry.invocation_started_event(), Nil, meta)
}

pub fn invocation_completed(
  duration_ms: Int,
  meta: telemetry.InvocationCompletedMeta,
) -> Nil {
  sinal.emit(
    telemetry.invocation_completed_event(),
    telemetry.InvocationCompletedMeasurements(duration_ms:),
    meta,
  )
}

pub fn invocation_cancelled(meta: telemetry.InvocationCancelledMeta) -> Nil {
  sinal.emit(telemetry.invocation_cancelled_event(), Nil, meta)
}

pub fn invocation_crashed(meta: telemetry.InvocationCrashedMeta) -> Nil {
  sinal.emit(telemetry.invocation_crashed_event(), Nil, meta)
}

pub fn exchange_closed(exchange_id: Int, listener: Option(String)) -> Nil {
  sinal.emit(
    telemetry.exchange_closed_event(),
    Nil,
    telemetry.ExchangeClosedMeta(exchange_id:, listener:),
  )
}

pub fn http_rejected(
  status: Int,
  reason: telemetry.RejectReason,
  correlation: Option(Correlation),
  listener: Option(String),
) -> Nil {
  sinal.emit(
    telemetry.http_rejected_event(),
    Nil,
    telemetry.HttpRejectedMeta(status:, reason:, correlation:, listener:),
  )
}

pub fn authorization_decided(
  verifier: String,
  decision: telemetry.Decision,
  correlation: Option(Correlation),
  listener: Option(String),
) -> Nil {
  sinal.emit(
    telemetry.authorization_decided_event(),
    Nil,
    telemetry.AuthorizationDecidedMeta(
      verifier:,
      decision:,
      correlation:,
      listener:,
    ),
  )
}

pub fn client_call(duration_ms: Int, meta: telemetry.ClientCallMeta) -> Nil {
  sinal.emit(
    telemetry.client_call_event(),
    telemetry.ClientCallMeasurements(duration_ms:),
    meta,
  )
}
