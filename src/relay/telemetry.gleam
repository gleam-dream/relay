//// The Sinal telemetry events Relay emits, as descriptors a handler
//// attaches to with `sinal.observe`.
////
//// | Event | When |
//// | --- | --- |
//// | `[relay, frame, rejected]` | a transport refused a frame before admission |
//// | `[relay, request, admitted]` | the server admitted a request |
//// | `[relay, invocation, started]` | a handler started |
//// | `[relay, invocation, completed]` | a handler returned; measures `duration_ms` |
//// | `[relay, invocation, cancelled]` | a running handler was cancelled |
//// | `[relay, invocation, crashed]` | a handler crashed or timed out |
//// | `[relay, exchange, closed]` | an exchange closed |
//// | `[relay, http, rejected]` | the HTTP endpoint refused a request |
//// | `[relay, authorization, decided]` | bearer admission granted or refused a request |
//// | `[relay, client, call]` | a client request finished; measures `duration_ms` |
////
//// Server events carry the method, the tool name when there is one, the
//// `sinal/correlation` the transport attached, and the `listener` label set
//// with `relay/http.with_label` or `relay/runtime.with_label`. Read metadata
//// by label: a later release may add fields. Status and reason fields are
//// enums, never prose.
////
//// ```gleam
//// import gleam/io
//// import gleam/option
//// import relay/telemetry
//// import sinal
////
//// pub fn log_tools() -> sinal.Attachment {
////   use _measured, meta <- sinal.observe(telemetry.invocation_started_event())
////   case meta.tool {
////     option.Some(name) -> io.println("tool " <> name)
////     option.None -> Nil
////   }
//// }
//// ```

import gleam/option.{type Option}
import sinal.{type Event}
import sinal/correlation.{type Correlation}
import sinal/fields.{type Fields}

/// Why a transport refused a frame.
pub type FrameProblem {
  FrameTooLarge
  TooManyExchanges
  NestingTooDeep
  TrailingBytes
}

/// How a handler finished.
pub type Status {
  Succeeded
  /// The tool returned an `isError` result.
  ToolFailed
  /// The handler asked the client for another input round.
  InputRequested
  /// The request failed with a JSON-RPC error.
  Failed
}

/// Why a handler stopped without a result.
pub type CrashReason {
  HandlerCrashed
  HandlerTimedOut
}

/// Why the HTTP endpoint refused a request before the server saw it.
pub type RejectReason {
  HostNotAllowed
  OriginNotAllowed
  MethodNotAllowed
  UnsupportedMediaType
  NotAcceptable
  BodyTooLarge
  MalformedBody
  RoutingHeaderMismatch
  TooManyRequests
  TooManyStreams
  Unauthenticated
}

/// What bearer admission decided.
pub type Decision {
  Granted
  MissingToken
  InvalidToken
  VerifierUnavailable
  WrongResource
  InsufficientScope
}

/// How a client request ended.
pub type CallOutcome {
  CallCompleted
  CallToolFailed
  CallInputRequired
  CallFailed
}

/// Metadata of `[relay, frame, rejected]`.
pub type FrameRejectedMeta {
  FrameRejectedMeta(
    exchange_id: Int,
    problem: FrameProblem,
    listener: Option(String),
  )
}

/// Metadata of `[relay, request, admitted]`.
pub type RequestAdmittedMeta {
  RequestAdmittedMeta(
    exchange_id: Int,
    method: String,
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Metadata of `[relay, invocation, started]`.
pub type InvocationStartedMeta {
  InvocationStartedMeta(
    exchange_id: Int,
    invocation_id: Int,
    method: String,
    tool: Option(String),
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Measurements of `[relay, invocation, completed]`: the handler's run time.
pub type InvocationCompletedMeasurements {
  InvocationCompletedMeasurements(duration_ms: Int)
}

/// Metadata of `[relay, invocation, completed]`.
pub type InvocationCompletedMeta {
  InvocationCompletedMeta(
    exchange_id: Int,
    invocation_id: Int,
    method: String,
    tool: Option(String),
    status: Status,
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Metadata of `[relay, invocation, cancelled]`.
pub type InvocationCancelledMeta {
  InvocationCancelledMeta(
    invocation_id: Int,
    method: String,
    tool: Option(String),
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Metadata of `[relay, invocation, crashed]`.
pub type InvocationCrashedMeta {
  InvocationCrashedMeta(
    invocation_id: Int,
    method: String,
    tool: Option(String),
    reason: CrashReason,
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Metadata of `[relay, exchange, closed]`.
pub type ExchangeClosedMeta {
  ExchangeClosedMeta(exchange_id: Int, listener: Option(String))
}

/// Metadata of `[relay, http, rejected]`.
pub type HttpRejectedMeta {
  HttpRejectedMeta(
    status: Int,
    reason: RejectReason,
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Metadata of `[relay, authorization, decided]`.
pub type AuthorizationDecidedMeta {
  AuthorizationDecidedMeta(
    verifier: String,
    decision: Decision,
    correlation: Option(Correlation),
    listener: Option(String),
  )
}

/// Measurements of `[relay, client, call]`: the request's round trip.
pub type ClientCallMeasurements {
  ClientCallMeasurements(duration_ms: Int)
}

/// Metadata of `[relay, client, call]`.
pub type ClientCallMeta {
  ClientCallMeta(
    method: String,
    tool: Option(String),
    outcome: CallOutcome,
    correlation: Option(Correlation),
    client: Option(String),
  )
}

// --- fields ------------------------------------------------------------------

fn listener() -> Fields(Option(String)) {
  fields.optional(fields.string("listener"))
}

fn tool_field() -> Fields(Option(String)) {
  fields.optional(fields.string("tool"))
}

fn frame_problem_name(problem: FrameProblem) -> String {
  case problem {
    FrameTooLarge -> "frame_too_large"
    TooManyExchanges -> "too_many_exchanges"
    NestingTooDeep -> "nesting_too_deep"
    TrailingBytes -> "trailing_bytes"
  }
}

fn status_name(status: Status) -> String {
  case status {
    Succeeded -> "succeeded"
    ToolFailed -> "tool_failed"
    InputRequested -> "input_requested"
    Failed -> "failed"
  }
}

fn crash_reason_name(reason: CrashReason) -> String {
  case reason {
    HandlerCrashed -> "crashed"
    HandlerTimedOut -> "timed_out"
  }
}

fn reject_reason_name(reason: RejectReason) -> String {
  case reason {
    HostNotAllowed -> "host_not_allowed"
    OriginNotAllowed -> "origin_not_allowed"
    MethodNotAllowed -> "method_not_allowed"
    UnsupportedMediaType -> "unsupported_media_type"
    NotAcceptable -> "not_acceptable"
    BodyTooLarge -> "body_too_large"
    MalformedBody -> "malformed_body"
    RoutingHeaderMismatch -> "routing_header_mismatch"
    TooManyRequests -> "too_many_requests"
    TooManyStreams -> "too_many_streams"
    Unauthenticated -> "unauthenticated"
  }
}

fn decision_name(decision: Decision) -> String {
  case decision {
    Granted -> "granted"
    MissingToken -> "missing_token"
    InvalidToken -> "invalid_token"
    VerifierUnavailable -> "verifier_unavailable"
    WrongResource -> "wrong_resource"
    InsufficientScope -> "insufficient_scope"
  }
}

fn call_outcome_name(outcome: CallOutcome) -> String {
  case outcome {
    CallCompleted -> "completed"
    CallToolFailed -> "tool_failed"
    CallInputRequired -> "input_required"
    CallFailed -> "failed"
  }
}

fn duration() -> Fields(Int) {
  fields.int("duration_ms")
}

// --- descriptors -------------------------------------------------------------

/// `[relay, frame, rejected]`.
pub fn frame_rejected_event() -> Event(Nil, FrameRejectedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use problem <- fields.include(
      fields.enum(
        "problem",
        [FrameTooLarge, TooManyExchanges, NestingTooDeep, TrailingBytes],
        frame_problem_name,
      ),
      get: fn(m) { m.problem },
    )
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(FrameRejectedMeta(exchange_id:, problem:, listener:))
  }
  sinal.event(["relay", "frame", "rejected"], fields.empty(), meta)
}

/// `[relay, request, admitted]`.
pub fn request_admitted_event() -> Event(Nil, RequestAdmittedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(RequestAdmittedMeta(
      exchange_id:,
      method:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "request", "admitted"], fields.empty(), meta)
}

/// `[relay, invocation, started]`. `tool` names the tool of a `tools/call`.
pub fn invocation_started_event() -> Event(Nil, InvocationStartedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use tool <- fields.include(tool_field(), get: fn(m) { m.tool })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(InvocationStartedMeta(
      exchange_id:,
      invocation_id:,
      method:,
      tool:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "invocation", "started"], fields.empty(), meta)
}

/// `[relay, invocation, completed]`, measuring the handler's run time.
pub fn invocation_completed_event() -> Event(
  InvocationCompletedMeasurements,
  InvocationCompletedMeta,
) {
  let measurements = {
    use duration_ms <- fields.include(duration(), get: fn(m) { m.duration_ms })
    fields.success(InvocationCompletedMeasurements(duration_ms:))
  }
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use tool <- fields.include(tool_field(), get: fn(m) { m.tool })
    use status <- fields.include(
      fields.enum(
        "status",
        [Succeeded, ToolFailed, InputRequested, Failed],
        status_name,
      ),
      get: fn(m) { m.status },
    )
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(InvocationCompletedMeta(
      exchange_id:,
      invocation_id:,
      method:,
      tool:,
      status:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "invocation", "completed"], measurements, meta)
}

/// `[relay, invocation, cancelled]`.
pub fn invocation_cancelled_event() -> Event(Nil, InvocationCancelledMeta) {
  let meta = {
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use tool <- fields.include(tool_field(), get: fn(m) { m.tool })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(InvocationCancelledMeta(
      invocation_id:,
      method:,
      tool:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "invocation", "cancelled"], fields.empty(), meta)
}

/// `[relay, invocation, crashed]`.
pub fn invocation_crashed_event() -> Event(Nil, InvocationCrashedMeta) {
  let meta = {
    use invocation_id <- fields.include(fields.int("invocation_id"), get: fn(m) {
      m.invocation_id
    })
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use tool <- fields.include(tool_field(), get: fn(m) { m.tool })
    use reason <- fields.include(
      fields.enum(
        "reason",
        [HandlerCrashed, HandlerTimedOut],
        crash_reason_name,
      ),
      get: fn(m) { m.reason },
    )
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(InvocationCrashedMeta(
      invocation_id:,
      method:,
      tool:,
      reason:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "invocation", "crashed"], fields.empty(), meta)
}

/// `[relay, exchange, closed]`.
pub fn exchange_closed_event() -> Event(Nil, ExchangeClosedMeta) {
  let meta = {
    use exchange_id <- fields.include(fields.int("exchange_id"), get: fn(m) {
      m.exchange_id
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(ExchangeClosedMeta(exchange_id:, listener:))
  }
  sinal.event(["relay", "exchange", "closed"], fields.empty(), meta)
}

/// `[relay, http, rejected]`: the HTTP status and why.
pub fn http_rejected_event() -> Event(Nil, HttpRejectedMeta) {
  let meta = {
    use status <- fields.include(fields.int("status"), get: fn(m) { m.status })
    use reason <- fields.include(
      fields.enum(
        "reason",
        [
          HostNotAllowed,
          OriginNotAllowed,
          MethodNotAllowed,
          UnsupportedMediaType,
          NotAcceptable,
          BodyTooLarge,
          MalformedBody,
          RoutingHeaderMismatch,
          TooManyRequests,
          TooManyStreams,
          Unauthenticated,
        ],
        reject_reason_name,
      ),
      get: fn(m) { m.reason },
    )
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(HttpRejectedMeta(status:, reason:, correlation:, listener:))
  }
  sinal.event(["relay", "http", "rejected"], fields.empty(), meta)
}

/// `[relay, authorization, decided]`: the verifier's name and the decision.
/// The token never appears.
pub fn authorization_decided_event() -> Event(Nil, AuthorizationDecidedMeta) {
  let meta = {
    use verifier <- fields.include(fields.string("verifier"), get: fn(m) {
      m.verifier
    })
    use decision <- fields.include(
      fields.enum(
        "decision",
        [
          Granted,
          MissingToken,
          InvalidToken,
          VerifierUnavailable,
          WrongResource,
          InsufficientScope,
        ],
        decision_name,
      ),
      get: fn(m) { m.decision },
    )
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use listener <- fields.include(listener(), get: fn(m) { m.listener })
    fields.success(AuthorizationDecidedMeta(
      verifier:,
      decision:,
      correlation:,
      listener:,
    ))
  }
  sinal.event(["relay", "authorization", "decided"], fields.empty(), meta)
}

/// `[relay, client, call]`, measuring the request's round trip.
pub fn client_call_event() -> Event(ClientCallMeasurements, ClientCallMeta) {
  let measurements = {
    use duration_ms <- fields.include(duration(), get: fn(m) { m.duration_ms })
    fields.success(ClientCallMeasurements(duration_ms:))
  }
  let meta = {
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use tool <- fields.include(tool_field(), get: fn(m) { m.tool })
    use outcome <- fields.include(
      fields.enum(
        "outcome",
        [CallCompleted, CallToolFailed, CallInputRequired, CallFailed],
        call_outcome_name,
      ),
      get: fn(m) { m.outcome },
    )
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use client <- fields.include(
      fields.optional(fields.string("client")),
      get: fn(m) { m.client },
    )
    fields.success(ClientCallMeta(
      method:,
      tool:,
      outcome:,
      correlation:,
      client:,
    ))
  }
  sinal.event(["relay", "client", "call"], measurements, meta)
}
