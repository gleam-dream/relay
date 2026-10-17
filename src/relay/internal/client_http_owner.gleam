//// Owns one HTTP client's header acquisition and opening budget. The caller
//// retains its HTTP Gun body; this process supplies only cancellation.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import http_gun/cancellation.{type Token}

pub type Failure {
  TimedOut
  Cancelled
  HeadersFailed
}

pub opaque type Owner {
  Owner(commands: Subject(Message), pid: Pid, token: Token)
}

type Message {
  Headers(Result(List(#(String, String)), String))
  Finish(Subject(Option(Failure)))
  Established(Subject(Result(Nil, Failure)))
  Down(process.Down)
  LinkedExit(process.ExitMessage)
}

type Phase {
  Acquiring(Subject(Result(#(List(#(String, String)), Owner), Failure)))
  Opening
  Streaming
  Stopped(Failure)
}

type State {
  State(
    owner: Owner,
    caller: process.Monitor,
    peer: Option(process.Monitor),
    worker: Option(#(Pid, process.Monitor)),
    phase: Phase,
    opening_deadline: Int,
    stream_deadline: Option(Int),
    cancellation: Option(Token),
  )
}

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn now() -> Int

@external(erlang, "relay_ffi", "rescue_run")
fn rescue(run: fn() -> a) -> Result(a, String)

// Public cancellation tokens expose a latch rather than a selector. Poll only
// that latch; caller/worker exits and commands wake the owner immediately.
const cancellation_poll_ms = 10

// The owned HTTP peer has one explicit close signal. Borrowed clients do not.
pub fn peer_lifetime() -> Pid {
  let parent = process.self()
  process.spawn_unlinked(fn() {
    let monitor = process.monitor(parent)
    let _ =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(_) { Nil })
      |> process.selector_receive_forever
    Nil
  })
}

pub fn acquire(
  headers: fn() -> List(#(String, String)),
  opening_deadline: Int,
  stream_deadline: Option(Int),
  cancellation: Option(Token),
  peer: Option(Pid),
) -> Result(#(List(#(String, String)), Owner), Failure) {
  let caller = process.self()
  let reply = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let parent = process.monitor(caller)
      use token <- cancellation.with_token
      let commands = process.new_subject()
      let owner = Owner(commands, process.self(), token)
      let worker =
        process.spawn(fn() { process.send(commands, Headers(rescue(headers))) })
      loop(State(
        owner,
        parent,
        option.map(peer, process.monitor),
        Some(#(worker, process.monitor(worker))),
        Acquiring(reply),
        opening_deadline,
        stream_deadline,
        cancellation,
      ))
    })
  let monitor = process.monitor(pid)
  let result =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Error(HeadersFailed) })
    |> process.selector_receive_forever
  let _ = process.demonitor_process(monitor)
  result
}

pub fn token(owner: Owner) -> Token {
  owner.token
}

pub fn finish(owner: Owner) -> Option(Failure) {
  let monitor = process.monitor(owner.pid)
  let reply = process.new_subject()
  process.send(owner.commands, Finish(reply))
  let result =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  case result {
    Ok(reason) -> {
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
      reason
    }
    Error(Nil) -> Some(Cancelled)
  }
}

pub fn establish(owner: Owner) -> Result(Nil, Failure) {
  let monitor = process.monitor(owner.pid)
  let reply = process.new_subject()
  process.send(owner.commands, Established(reply))
  let result =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Cancelled) })
    |> process.selector_receive_forever
  let _ = process.demonitor_process(monitor)
  result
}

fn bound(state: State) -> Option(Int) {
  case state.phase {
    Streaming -> state.stream_deadline
    Stopped(_) -> None
    Acquiring(_) | Opening -> Some(state.opening_deadline)
  }
}

fn failure(state: State) -> Option(Failure) {
  case state.phase {
    Stopped(reason) -> Some(reason)
    _ -> {
      let cancelled = case state.cancellation {
        Some(token) -> cancellation.is_cancelled(token)
        None -> False
      }
      let expired = case bound(state) {
        Some(at) -> now() >= at
        None -> False
      }
      case cancelled, expired {
        True, _ -> Some(Cancelled)
        False, True -> Some(TimedOut)
        False, False -> None
      }
    }
  }
}

fn stop_worker(worker: Option(#(Pid, process.Monitor))) -> Nil {
  case worker {
    None -> Nil
    Some(#(pid, monitor)) -> {
      process.kill(pid)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_) { Nil })
        |> process.selector_receive_forever
      Nil
    }
  }
}

fn loop(state: State) -> Nil {
  case state.phase, failure(state) {
    Acquiring(reply), Some(reason) -> {
      stop_worker(state.worker)
      process.send(reply, Error(reason))
    }
    Opening, Some(reason) | Streaming, Some(reason) -> {
      cancellation.cancel(state.owner.token)
      loop(State(..state, phase: Stopped(reason)))
    }
    _, _ -> receive(state)
  }
}

fn receive(state: State) -> Nil {
  let deadline_wait =
    option.map(bound(state), fn(at) { int.max(0, at - now()) })
  let wait = case state.phase, state.cancellation, deadline_wait {
    Stopped(_), _, _ -> None
    _, Some(_), Some(left) -> Some(int.min(cancellation_poll_ms, left))
    _, Some(_), None -> Some(cancellation_poll_ms)
    _, None, remaining -> remaining
  }
  let selector =
    process.new_selector()
    |> process.select(state.owner.commands)
    |> process.select_monitors(Down)
    |> process.select_trapped_exits(LinkedExit)
  let message = case wait {
    Some(wait) -> process.selector_receive(selector, wait)
    None -> Ok(process.selector_receive_forever(selector))
  }
  case message {
    Error(Nil) -> loop(state)
    Ok(Down(process.ProcessDown(monitor: monitor, ..))) ->
      case monitor == state.caller, state.peer == Some(monitor), state.phase {
        True, _, _ -> stop_worker(state.worker)
        False, True, Acquiring(reply) -> {
          stop_worker(state.worker)
          process.send(reply, Error(Cancelled))
        }
        False, True, _ -> {
          cancellation.cancel(state.owner.token)
          loop(State(..state, phase: Stopped(Cancelled)))
        }
        False, False, Acquiring(reply) ->
          process.send(reply, Error(HeadersFailed))
        False, False, _ -> loop(state)
      }
    Ok(Down(process.PortDown(..))) -> loop(state)
    Ok(LinkedExit(_)) -> loop(state)
    Ok(Headers(result)) -> {
      stop_worker(state.worker)
      let state = State(..state, worker: None)
      case state.phase, failure(state), result {
        Acquiring(reply), Some(reason), _ -> process.send(reply, Error(reason))
        Acquiring(reply), None, Error(_) ->
          process.send(reply, Error(HeadersFailed))
        Acquiring(reply), None, Ok(headers) -> {
          process.send(reply, Ok(#(headers, state.owner)))
          loop(State(..state, phase: Opening))
        }
        _, _, _ -> loop(state)
      }
    }
    Ok(Finish(reply)) -> process.send(reply, failure(state))
    Ok(Established(reply)) ->
      case failure(state) {
        Some(reason) -> {
          process.send(reply, Error(reason))
          loop(state)
        }
        None -> {
          process.send(reply, Ok(Nil))
          loop(State(..state, phase: Streaming))
        }
      }
  }
}
