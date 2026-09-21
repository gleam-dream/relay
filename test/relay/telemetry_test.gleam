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
  let assert Ok(hid) = sinal.handler_id("test_frame_rejected")
  let ev = telemetry.frame_rejected_event()
  let h =
    sinal.handler(fn(_ev, _meas, meta: telemetry.FrameRejectedMeta) {
      process.send(subj, meta)
      Ok(Nil)
    })

  let assert Ok(att) = sinal.attach(hid, ev, h, fn(_, _) { Nil })

  telemetry.emit_frame_rejected(42, "syntax error")

  let assert Ok(received) = process.receive(subj, 500)
  received.exchange_id |> should.equal(42)
  received.reason |> should.equal("syntax error")

  let assert Ok(Nil) = sinal.detach(att)
}

pub fn request_admitted_observation_test() {
  let subj = process.new_subject()
  let assert Ok(hid) = sinal.handler_id("test_request_admitted")
  let ev = telemetry.request_admitted_event()
  let h =
    sinal.handler(fn(_ev, _meas, meta: telemetry.RequestAdmittedMeta) {
      process.send(subj, meta)
      Ok(Nil)
    })

  let assert Ok(att) = sinal.attach(hid, ev, h, fn(_, _) { Nil })

  telemetry.emit_request_admitted(99, "server/discover")

  let assert Ok(received) = process.receive(subj, 500)
  received.exchange_id |> should.equal(99)
  received.method |> should.equal("server/discover")

  let assert Ok(Nil) = sinal.detach(att)
}

pub fn invocation_lifecycle_observation_test() {
  let started_subj = process.new_subject()
  let completed_subj = process.new_subject()

  let assert Ok(hid1) = sinal.handler_id("test_inv_started")
  let ev1 = telemetry.invocation_started_event()
  let h1 =
    sinal.handler(fn(_ev, _meas, meta: telemetry.InvocationStartedMeta) {
      process.send(started_subj, meta)
      Ok(Nil)
    })
  let assert Ok(att1) = sinal.attach(hid1, ev1, h1, fn(_, _) { Nil })

  let assert Ok(hid2) = sinal.handler_id("test_inv_completed")
  let ev2 = telemetry.invocation_completed_event()
  let h2 =
    sinal.handler(
      fn(
        _ev,
        meas: telemetry.InvocationCompletedMeasurements,
        meta: telemetry.InvocationCompletedMeta,
      ) {
        process.send(completed_subj, #(meas, meta))
        Ok(Nil)
      },
    )
  let assert Ok(att2) = sinal.attach(hid2, ev2, h2, fn(_, _) { Nil })

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

  let assert Ok(hid_can) = sinal.handler_id("test_cancel")
  let ev_can = telemetry.invocation_cancelled_event()
  let h_can =
    sinal.handler(fn(_ev, _meas, meta: telemetry.InvocationCancelledMeta) {
      process.send(cancel_subj, meta)
      Ok(Nil)
    })
  let assert Ok(att_can) =
    sinal.attach(hid_can, ev_can, h_can, fn(_, _) { Nil })

  let assert Ok(hid_cra) = sinal.handler_id("test_crash")
  let ev_cra = telemetry.invocation_crashed_event()
  let h_cra =
    sinal.handler(fn(_ev, _meas, meta: telemetry.InvocationCrashedMeta) {
      process.send(crash_subj, meta)
      Ok(Nil)
    })
  let assert Ok(att_cra) =
    sinal.attach(hid_cra, ev_cra, h_cra, fn(_, _) { Nil })

  let assert Ok(hid_clo) = sinal.handler_id("test_close")
  let ev_clo = telemetry.exchange_closed_event()
  let h_clo =
    sinal.handler(fn(_ev, _meas, meta: telemetry.ExchangeClosedMeta) {
      process.send(close_subj, meta)
      Ok(Nil)
    })
  let assert Ok(att_clo) =
    sinal.attach(hid_clo, ev_clo, h_clo, fn(_, _) { Nil })

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
