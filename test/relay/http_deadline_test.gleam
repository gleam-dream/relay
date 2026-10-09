import gleam/erlang/process
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import relay/http
import relay/server
import relay/testing
import sinal/correlation

pub fn blocked_correlation_obeys_admitted_request_deadline_test() {
  let entered = process.new_subject()
  let answered = process.new_subject()
  let config =
    http.new(server.new([]))
    |> http.with_correlation(fn(_) {
      let release = process.new_subject()
      process.send(entered, #(process.self(), release))
      let _ = process.receive(release, 2000)
      Some(correlation.unique())
    })
    |> http.with_request_timeout(duration.milliseconds(30))
    |> http.with_cancellation_grace(duration.milliseconds(20))
  let assert Ok(endpoint) = http.handler(config)
  let caller =
    process.spawn_unlinked(fn() {
      http.handle(endpoint, testing.request("tools/list", []))
      |> fn(reply) { process.send(answered, reply.status) }
    })
  let assert Ok(#(worker, release)) = process.receive(entered, 1000)
  let reply = process.receive(answered, 200)
  process.send(release, Nil)
  http.stop(endpoint)
  process.kill(worker)
  process.kill(caller)
  reply |> should.equal(Ok(504))
}
