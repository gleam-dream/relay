//// One admitted HTTP request owns its callback worker and runtime children.
//// This coordinator creates internal children, so cancellation cannot
//// race between their creation and registration. Mist registers its stream writer
//// before the first pull. Socket messages remain in the
//// serving process and are forwarded here. No application callback runs here.

import gleam/bytes_tree
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http/response
import gleam/int
import gleam/option.{type Option, None, Some}
import relay/internal/http_mist

@external(erlang, "relay_ffi", "monotonic_time_ms")
fn now() -> Int

pub type Setup {
  Setup(
    deadline: Int,
    grace: Int,
    subscription: Bool,
    settled: fn() -> Bool,
    run: fn(Scope) -> http_mist.Reply,
  )
}

pub opaque type Scope {
  Scope(subject: Subject(Message), deadline: Int)
}

type FailureOwner {
  RequestFailure
  RuntimeFailure
}

type Resource {
  Resource(
    pid: Pid,
    monitor: process.Monitor,
    stop: fn() -> Nil,
    stopped: Bool,
    failure_owner: FailureOwner,
  )
}

type Message {
  Child(start: fn() -> Option(Resource), refused: fn() -> Nil)
  WriteBudget(per_write: Int, reply: Subject(Result(Int, Nil)))
  CancelChild(Pid)
  Authorize(Subject(Bool))
  Completed(http_mist.Reply)
  Cancel
  StreamOwner(Pid, Subject(Bool))
  Established
  Down(process.Down)
  LinkedExit(process.ExitMessage)
}

type Answer {
  Answer(http_mist.Reply)
  Gone
}

type State {
  State(
    scope: Scope,
    resources: Dict(Pid, Resource),
    worker: Pid,
    parent: process.Monitor,
    endpoint: process.Monitor,
    stream_owner: Option(Pid),
    reply: Subject(Answer),
    pending: Option(http_mist.Reply),
    settled: fn() -> Bool,
    answered: Bool,
    completed: Bool,
    streaming: Bool,
    subscription: Bool,
    established: Bool,
    grace: Int,
    retiring: Option(Int),
    forced: Bool,
  )
}

pub fn remaining(scope: Scope) -> Int {
  int.max(0, scope.deadline - now())
}

pub fn start_child(
  scope: Scope,
  start: fn() -> Result(#(Pid, child), Nil),
  stop: fn(child) -> Nil,
) -> Result(child, Nil) {
  start_child_for(scope, start, stop, RequestFailure)
}

fn start_child_for(
  scope: Scope,
  start: fn() -> Result(#(Pid, child), Nil),
  stop: fn(child) -> Nil,
  failure_owner: FailureOwner,
) -> Result(child, Nil) {
  let reply = process.new_subject()
  let create = fn() {
    case start() {
      Error(Nil) -> {
        process.send(reply, Error(Nil))
        None
      }
      Ok(#(pid, child)) -> {
        let resource =
          Resource(
            pid,
            process.monitor(pid),
            fn() { stop(child) },
            False,
            failure_owner,
          )
        process.send(reply, Ok(child))
        Some(resource)
      }
    }
  }
  case process.subject_owner(scope.subject) {
    Error(Nil) -> Error(Nil)
    Ok(owner) -> {
      let monitor = process.monitor(owner)
      process.send(
        scope.subject,
        Child(create, fn() { process.send(reply, Error(Nil)) }),
      )
      let answer =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(int.max(1, remaining(scope)))
      let _ = process.demonitor_process(monitor)
      case answer {
        Ok(answer) -> answer
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

pub fn spawn(
  scope: Scope,
  run: fn() -> Nil,
  cancel: fn(Pid) -> Nil,
) -> Result(Pid, Nil) {
  start_child_for(
    scope,
    fn() {
      let pid =
        process.spawn_unlinked(fn() {
          // A scheduler may delay a registered child past its authorization time.
          case authorized(scope) {
            True -> run()
            False -> Nil
          }
        })
      Ok(#(pid, pid))
    },
    cancel,
    RuntimeFailure,
  )
}

pub fn cancel_child(scope: Scope, pid: Pid) -> Nil {
  process.send(scope.subject, CancelChild(pid))
}

pub fn authorized(scope: Scope) -> Bool {
  let reply = process.new_subject()
  process.send(scope.subject, Authorize(reply))
  case process.receive(reply, int.max(1, remaining(scope))) {
    Ok(True) -> remaining(scope) > 0
    _ -> False
  }
}

pub fn run(
  endpoint: Pid,
  closed: process.Selector(Nil),
  prepare: fn(fn() -> Nil) -> Result(Setup, http_mist.Reply),
) -> http_mist.Reply {
  let caller = process.self()
  let ready = process.new_subject()
  let answers = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let subject = process.new_subject()
      process.send(ready, subject)
      let parent = process.monitor(caller)
      let endpoint = process.monitor(endpoint)
      case prepare(fn() { process.send(subject, Cancel) }) {
        Error(reply) -> process.send(answers, Answer(reply))
        Ok(setup) -> {
          let scope = Scope(subject, setup.deadline)
          let worker =
            process.spawn_unlinked(fn() {
              let answer = setup.run(scope)
              process.send(subject, Completed(answer))
              process.sleep_forever()
            })
          let resource =
            Resource(
              worker,
              process.monitor(worker),
              fn() { Nil },
              False,
              RequestFailure,
            )
          loop(State(
            scope,
            dict.from_list([#(worker, resource)]),
            worker,
            parent,
            endpoint,
            None,
            answers,
            None,
            setup.settled,
            False,
            False,
            False,
            setup.subscription,
            False,
            setup.grace,
            None,
            False,
          ))
        }
      }
    })
  let monitor = process.monitor(owner)
  let assert Ok(subject) = process.receive(ready, 5000)
  let answer =
    closed
    |> process.map_selector(fn(_) { Gone })
    |> process.select(answers)
    |> process.select_specific_monitor(monitor, fn(_) { Answer(failure(500)) })
    |> process.selector_receive_forever
  let _ = process.demonitor_process(monitor)
  case answer {
    Answer(reply) -> reply
    Gone -> {
      process.send(subject, Cancel)
      failure(499)
    }
  }
}

fn failure(status: Int) -> http_mist.Reply {
  http_mist.Buffered(
    response.new(status)
    |> response.set_header("connection", "close")
    |> response.set_body(bytes_tree.from_string("Relay request ended")),
  )
}

fn loop(state: State) -> Nil {
  let state = expire(state)
  case dict.is_empty(state.resources) {
    True -> {
      case state.pending, state.answered {
        Some(reply), False -> {
          let reply = case
            remaining(state.scope) > 0
            && state.settled()
            && remaining(state.scope) > 0
          {
            True -> reply
            False -> failure(504)
          }
          let _ = answer(state, reply)
          Nil
        }
        _, _ -> Nil
      }
    }
    False -> {
      let wait = case state.retiring, state.established {
        Some(deadline), _ -> int.max(0, deadline - now())
        None, False -> remaining(state.scope)
        None, True -> 60_000
      }
      let wait = case state.forced {
        True -> 60_000
        False -> wait
      }
      let wait = case state.pending, state.answered {
        Some(_), False -> int.min(wait, remaining(state.scope))
        _, _ -> wait
      }
      let event =
        process.new_selector()
        |> process.select(state.scope.subject)
        |> process.select_monitors(Down)
        |> process.select_trapped_exits(LinkedExit)
        |> process.selector_receive(wait)
      case event {
        Error(Nil) -> loop(state)
        Ok(event) -> loop(handle(expire(state), event))
      }
    }
  }
}

fn expire(state: State) -> State {
  let state = case state.pending, state.answered {
    Some(_), False ->
      case remaining(state.scope) <= 0 {
        True -> answer(state, failure(504))
        False -> state
      }
    _, _ -> state
  }
  case state.retiring {
    None -> {
      case !state.established && remaining(state.scope) <= 0 {
        True -> retire(answer(state, failure(504)))
        False -> state
      }
    }
    Some(deadline) -> {
      case !state.forced && now() >= deadline {
        True -> {
          dict.each(state.resources, fn(pid, _) { process.kill(pid) })
          State(..state, forced: True)
        }
        False -> state
      }
    }
  }
}

fn answer(state: State, reply: http_mist.Reply) -> State {
  case state.answered {
    True -> state
    False -> {
      process.send(state.reply, Answer(reply))
      State(..state, answered: True)
    }
  }
}

fn retire(state: State) -> State {
  case state.retiring {
    Some(_) -> state
    None -> {
      let resources =
        dict.map_values(state.resources, fn(_, resource) {
          cancel_resource(resource)
        })
      let state =
        State(
          ..state,
          resources: resources,
          retiring: Some(now() + state.grace),
        )
      retire_worker_if_last(state)
    }
  }
}

fn cancel_resource(resource: Resource) -> Resource {
  case resource.stopped {
    True -> resource
    False -> {
      resource.stop()
      Resource(..resource, stopped: True)
    }
  }
}

fn retire_worker_if_last(state: State) -> State {
  case state.retiring {
    Some(_) -> {
      case
        state.completed
        && dict.size(state.resources) == 1
        && dict.has_key(state.resources, state.worker)
      {
        True -> process.kill(state.worker)
        False -> Nil
      }
      state
    }
    None -> state
  }
}

fn handle(state: State, message: Message) -> State {
  case message {
    Child(start, refused) -> {
      case state.retiring {
        Some(_) -> {
          refused()
          state
        }
        None -> {
          case start() {
            None -> state
            Some(resource) ->
              State(
                ..state,
                resources: dict.insert(state.resources, resource.pid, resource),
              )
          }
        }
      }
    }
    WriteBudget(per_write, reply) -> {
      let budget = case state.retiring, state.established {
        Some(_), _ -> Error(Nil)
        None, True -> Ok(per_write)
        None, False -> Ok(int.min(per_write, remaining(state.scope)))
      }
      process.send(reply, budget)
      state
    }
    CancelChild(pid) -> {
      case dict.get(state.resources, pid) {
        Error(Nil) -> state
        Ok(resource) ->
          State(
            ..state,
            resources: dict.insert(
              state.resources,
              pid,
              cancel_resource(resource),
            ),
          )
      }
    }
    Authorize(reply) -> {
      process.send(reply, state.retiring == None && remaining(state.scope) > 0)
      state
    }
    Completed(reply) -> {
      let state = State(..state, completed: True)
      case state.retiring {
        Some(_) -> state
        None -> {
          case reply {
            http_mist.Buffered(_) ->
              retire(State(..state, pending: Some(reply)))
            http_mist.Streamed(..) ->
              answer(
                State(..state, streaming: True),
                wrap_stream(state.scope, state.subscription, reply),
              )
          }
        }
      }
    }
    Cancel -> retire(answer(state, failure(499)))
    Established -> {
      case state.retiring {
        None -> State(..state, established: True)
        Some(_) -> state
      }
    }
    StreamOwner(pid, reply) -> {
      process.send(reply, state.retiring == None)
      case state.stream_owner {
        Some(existing) if existing == pid -> state
        _ -> {
          let _ = process.demonitor_process(state.parent)
          let resource =
            Resource(
              pid,
              process.monitor(pid),
              fn() { process.kill(pid) },
              False,
              RequestFailure,
            )
          let state =
            State(
              ..state,
              parent: process.monitor(pid),
              stream_owner: Some(pid),
              resources: dict.insert(state.resources, pid, resource),
            )
          case state.retiring {
            Some(_) -> process.kill(pid)
            None -> Nil
          }
          state
        }
      }
    }
    Down(process.ProcessDown(monitor: monitor, pid: pid, reason: reason)) -> {
      case monitor == state.endpoint, monitor == state.parent {
        True, _ -> retire(answer(state, failure(503)))
        _, True -> {
          case state.streaming, state.stream_owner, reason {
            True, None, process.Normal -> state
            _, _, _ -> retire(answer(state, failure(499)))
          }
        }
        False, False -> {
          let failure_owner = case dict.get(state.resources, pid) {
            Ok(resource) -> resource.failure_owner
            Error(Nil) -> RequestFailure
          }
          let state =
            State(..state, resources: dict.delete(state.resources, pid))
          case
            state.retiring,
            pid == state.worker && !state.completed,
            reason,
            failure_owner
          {
            Some(_), _, _, _ -> retire_worker_if_last(state)
            None, True, _, _ -> retire(answer(state, failure(500)))
            None, False, _, RuntimeFailure -> retire_worker_if_last(state)
            None, False, process.Normal, RequestFailure ->
              retire_worker_if_last(state)
            None, False, _, RequestFailure ->
              retire(answer(state, failure(500))) |> retire_worker_if_last
          }
        }
      }
    }
    Down(_) | LinkedExit(_) -> state
  }
}

fn stream_budget(scope: Scope, per_write: Int) -> Result(Int, Nil) {
  let reply = process.new_subject()
  case process.subject_owner(scope.subject) {
    Error(Nil) -> Error(Nil)
    Ok(owner) -> {
      let monitor = process.monitor(owner)
      process.send(scope.subject, WriteBudget(per_write, reply))
      let answer =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(per_write)
      let _ = process.demonitor_process(monitor)
      case answer {
        Ok(answer) -> answer
        Error(Nil) -> Error(Nil)
      }
    }
  }
}

fn wrap_stream(
  scope: Scope,
  subscription: Bool,
  reply: http_mist.Reply,
) -> http_mist.Reply {
  let assert http_mist.Streamed(
    head,
    next,
    close,
    keepalive,
    budget,
    written,
    _attached,
  ) = reply
  let assert Ok(per_write) = budget()
  http_mist.Streamed(
    head,
    next,
    fn() {
      close()
      process.send(scope.subject, Cancel)
    },
    keepalive,
    fn() { stream_budget(scope, per_write) },
    fn(event) {
      written(event)
      case event {
        http_mist.Data(_) if subscription ->
          process.send(scope.subject, Established)
        _ -> Nil
      }
    },
    fn(pid) { attach_stream(scope, pid) },
  )
}

fn attach_stream(scope: Scope, pid: Pid) -> Bool {
  let reply = process.new_subject()
  case process.subject_owner(scope.subject) {
    Error(Nil) -> False
    Ok(owner) -> {
      let monitor = process.monitor(owner)
      process.send(scope.subject, StreamOwner(pid, reply))
      let attached =
        process.new_selector()
        |> process.select(reply)
        |> process.select_specific_monitor(monitor, fn(_) { False })
        |> process.selector_receive(int.max(1, remaining(scope)))
      let _ = process.demonitor_process(monitor)
      attached == Ok(True)
    }
  }
}
