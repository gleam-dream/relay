import gleam/erlang/process
import gleeunit
import gleeunit/should
import relay/telemetry
import sinal

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn frame_rejected_observation_test() {
  let subj = process.new_subject()
  let ev = telemetry.frame_rejected_event()
  let h = fn(_meas, meta: telemetry.FrameRejectedMeta) {
    process.send(subj, meta)
  }

  let att = sinal.observe(ev, h)

  telemetry.emit_frame_rejected(42, "syntax error")

  let assert Ok(received) = process.receive(subj, 500)
  received.exchange_id |> should.equal(42)
  received.reason |> should.equal("syntax error")

  let assert Ok(Nil) = sinal.detach(att)
}

pub fn request_admitted_observation_test() {
  let subj = process.new_subject()
  let ev = telemetry.request_admitted_event()
  let h = fn(_meas, meta: telemetry.RequestAdmittedMeta) {
    process.send(subj, meta)
  }

  let att = sinal.observe(ev, h)

  telemetry.emit_request_admitted(99, "server/discover")

  let assert Ok(received) = process.receive(subj, 500)
  received.exchange_id |> should.equal(99)
  received.method |> should.equal("server/discover")

  let assert Ok(Nil) = sinal.detach(att)
}

pub fn invocation_lifecycle_observation_test() {
  let started_subj = process.new_subject()
  let completed_subj = process.new_subject()

  let ev1 = telemetry.invocation_started_event()
  let h1 = fn(_meas, meta: telemetry.InvocationStartedMeta) {
    process.send(started_subj, meta)
  }
  let att1 = sinal.observe(ev1, h1)

  let ev2 = telemetry.invocation_completed_event()
  let h2 = fn(
    meas: telemetry.InvocationCompletedMeasurements,
    meta: telemetry.InvocationCompletedMeta,
  ) {
    process.send(completed_subj, #(meas, meta))
  }
  let att2 = sinal.observe(ev2, h2)

  telemetry.emit_invocation_started(1, 10, "greet")
  let assert Ok(started) = process.receive(started_subj, 500)
  started.exchange_id |> should.equal(1)
  started.invocation_id |> should.equal(10)
  started.tool_name |> should.equal("greet")

  telemetry.emit_invocation_completed(1, 10, 25, "success")
  let assert Ok(#(meas, completed)) = process.receive(completed_subj, 500)
  meas.duration_ms |> should.equal(25)
  completed.exchange_id |> should.equal(1)
  completed.invocation_id |> should.equal(10)
  completed.status |> should.equal("success")

  let assert Ok(Nil) = sinal.detach(att1)
  let assert Ok(Nil) = sinal.detach(att2)
}

pub fn crash_and_cancel_observation_test() {
  let cancel_subj = process.new_subject()
  let crash_subj = process.new_subject()
  let close_subj = process.new_subject()

  let ev_can = telemetry.invocation_cancelled_event()
  let h_can = fn(_meas, meta: telemetry.InvocationCancelledMeta) {
    process.send(cancel_subj, meta)
  }
  let att_can = sinal.observe(ev_can, h_can)

  let ev_cra = telemetry.invocation_crashed_event()
  let h_cra = fn(_meas, meta: telemetry.InvocationCrashedMeta) {
    process.send(crash_subj, meta)
  }
  let att_cra = sinal.observe(ev_cra, h_cra)

  let ev_clo = telemetry.exchange_closed_event()
  let h_clo = fn(_meas, meta: telemetry.ExchangeClosedMeta) {
    process.send(close_subj, meta)
  }
  let att_clo = sinal.observe(ev_clo, h_clo)

  telemetry.emit_invocation_cancelled(55)
  let assert Ok(can) = process.receive(cancel_subj, 500)
  can.invocation_id |> should.equal(55)

  telemetry.emit_invocation_crashed(55, "badarg")
  let assert Ok(cra) = process.receive(crash_subj, 500)
  cra.invocation_id |> should.equal(55)
  cra.reason |> should.equal("badarg")

  telemetry.emit_exchange_closed(101)
  let assert Ok(clo) = process.receive(close_subj, 500)
  clo.exchange_id |> should.equal(101)

  let assert Ok(Nil) = sinal.detach(att_can)
  let assert Ok(Nil) = sinal.detach(att_cra)
  let assert Ok(Nil) = sinal.detach(att_clo)
}
