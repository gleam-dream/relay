//// The stdio client when a caller gives up: a late response is dropped, a
//// request that waited too long is never written, and a listener does not
//// hold other callers.

import gleam/erlang/process
import gleam/option.{None}
import gleam/time/duration
import http_gun/cancellation
import http_gun/deadline
import json/blueprint/codec.{type Codec}
import relay/client
import relay/content
import relay/reason_support
import relay/subscriptions
import relay/tool

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn monotonic_ms() -> Int

fn milliseconds() -> Codec(Int) {
  use value <- codec.field("ms", codec.int(), get: fn(value) { value })
  codec.success(value)
}

fn scripted(name: String) -> tool.Definition(Int, List(content.ContentBlock)) {
  tool.define_content(name, milliseconds())
}

fn connect() -> client.Client {
  let assert Ok(peer) =
    client.stdio("python3", ["test/fixtures/stdio/scripted-peer.py"])
    |> client.with_timeout(duration.seconds(5))
    |> client.connect
  peer
}

fn answer(peer: client.Client, name: String) -> String {
  let assert Ok(client.Succeeded(blocks, _)) =
    client.call(peer, scripted(name), 0)
  content.text_of(blocks)
}

// Starts a 1.2 s call in another process and returns once it is in flight.
fn hold_the_child(peer: client.Client) -> process.Subject(Bool) {
  let held = process.new_subject()
  let _ =
    process.spawn(fn() {
      let outcome = client.call(peer, scripted("hold"), 1200)
      process.send(held, case outcome {
        Ok(client.Succeeded(_, _)) -> True
        _ -> False
      })
    })
  process.sleep(200)
  held
}

pub fn late_response_after_cancellation_is_dropped_test() {
  let peer = connect()
  let outcome = {
    use token <- cancellation.with_token
    let _ =
      process.spawn(fn() {
        process.sleep(200)
        cancellation.cancel(token)
      })
    peer
    |> client.with_cancellation(token)
    |> client.call(scripted("late"), 0)
  }
  let assert Error(client.Cancelled(_)) = outcome |> reason_support.of
  // The peer answered the cancelled request after the cancellation. The
  // next call still gets its own answer from the same child.
  assert answer(peer, "cancels") == "1"
  assert answer(peer, "count") == "0"
  client.close(peer)
}

pub fn request_that_timed_out_while_waiting_is_never_written_test() {
  let peer = connect()
  let held = hold_the_child(peer)
  let assert Error(client.TimedOut(_)) =
    peer
    |> client.with_deadline(deadline.after(duration.milliseconds(300)))
    |> client.call(scripted("mutate"), 0)
    |> reason_support.of
  let assert Ok(True) = process.receive(held, 5000)
  assert answer(peer, "count") == "0"
  client.close(peer)
}

pub fn request_cancelled_while_waiting_is_never_written_test() {
  let peer = connect()
  let held = hold_the_child(peer)
  let outcome = {
    use token <- cancellation.with_token
    let _ =
      process.spawn(fn() {
        process.sleep(200)
        cancellation.cancel(token)
      })
    peer
    |> client.with_cancellation(token)
    |> client.call(scripted("mutate"), 0)
  }
  let assert Error(client.Cancelled(_)) = outcome |> reason_support.of
  let assert Ok(True) = process.receive(held, 5000)
  assert answer(peer, "count") == "0"
  client.close(peer)
}

pub fn request_whose_caller_exited_while_waiting_is_never_written_test() {
  let peer = connect()
  let held = hold_the_child(peer)
  let caller =
    process.spawn_unlinked(fn() { client.call(peer, scripted("mutate"), 0) })
  process.sleep(200)
  process.kill(caller)
  let assert Ok(True) = process.receive(held, 5000)
  assert answer(peer, "count") == "0"
  client.close(peer)
}

pub fn caller_exit_cancels_its_request_in_flight_test() {
  let peer = connect()
  let caller =
    process.spawn_unlinked(fn() { client.call(peer, scripted("late"), 0) })
  process.sleep(200)
  process.kill(caller)
  // The child is told at once and stays usable; without the cancellation
  // the abandoned request would hold the child until its timeout.
  let started = monotonic_ms()
  assert answer(peer, "cancels") == "1"
  assert monotonic_ms() - started < 2000
  client.close(peer)
}

pub fn waiting_for_a_notification_does_not_hold_other_callers_test() {
  let peer = connect()
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let called = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.sleep(200)
      let started = monotonic_ms()
      let first = answer(peer, "mutate")
      let second = answer(peer, "count")
      process.send(called, #(first, second, monotonic_ms() - started))
    })
  let assert Ok(None) =
    client.next_notification(subscription, duration.milliseconds(1500))
  let assert Ok(#("mutated", "1", elapsed)) = process.receive(called, 5000)
  assert elapsed < 1000
  client.close_subscription(subscription)
  client.close(peer)
}

pub fn request_that_times_out_during_a_notification_wait_is_cancelled_test() {
  let peer = connect()
  let assert Ok(subscription) =
    client.listen(peer, [subscriptions.ToolsListChanged])
  let called = process.new_subject()
  let _ =
    process.spawn(fn() {
      process.sleep(100)
      let outcome =
        peer
        |> client.with_deadline(deadline.after(duration.milliseconds(300)))
        |> client.call(scripted("late"), 0)
        |> reason_support.of
      process.send(called, outcome)
    })
  let started = monotonic_ms()
  let assert Ok(None) =
    client.next_notification(subscription, duration.milliseconds(1500))
  // The request's timeout is not the end of the notification wait.
  assert monotonic_ms() - started >= 1400
  let assert Ok(Error(client.TimedOut(_))) = process.receive(called, 1000)
  // The child was told, its late answer was dropped, and it stays usable.
  assert answer(peer, "cancels") == "1"
  client.close_subscription(subscription)
  client.close(peer)
}
