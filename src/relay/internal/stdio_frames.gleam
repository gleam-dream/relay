//// Newline framing and a serialized writer for stdio transports.

import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type ReadOutcome {
  ReadChunk(BitArray)
  ReadEof
  ReadFailed(String)
}

pub type FramerResult {
  Frame(BitArray)
  FrameOversized(size: Int, limit: Int)
  InvalidTrailingBytes(BitArray)
}

pub opaque type Framer {
  Framer(buffer: BitArray, max_frame_bytes: Int, dropping_oversized_tail: Bool)
}

/// Constructs a new framer with a maximum line byte limit.
pub fn new_framer(max_frame_bytes: Int) -> Framer {
  Framer(
    buffer: <<>>,
    max_frame_bytes: max_frame_bytes,
    dropping_oversized_tail: False,
  )
}

/// Feeds a chunk of bytes to the framer and extracts all complete newline-delimited frames.
pub fn feed_framer(
  framer: Framer,
  chunk: BitArray,
) -> #(Framer, List(FramerResult)) {
  let #(input, still_dropping) =
    discard_oversized_tail(framer.dropping_oversized_tail, chunk)
  case still_dropping {
    True -> #(
      Framer(
        buffer: <<>>,
        max_frame_bytes: framer.max_frame_bytes,
        dropping_oversized_tail: True,
      ),
      [],
    )
    False -> {
      let combined = bit_array.append(framer.buffer, input)
      let #(remaining, frames, dropping_tail) =
        extract_frames(combined, framer.max_frame_bytes, [])
      #(
        Framer(
          buffer: remaining,
          max_frame_bytes: framer.max_frame_bytes,
          dropping_oversized_tail: dropping_tail,
        ),
        frames,
      )
    }
  }
}

/// Finishes the framer at EOF, reporting any trailing bytes without newline.
pub fn finish_framer(framer: Framer) -> List(FramerResult) {
  case framer.dropping_oversized_tail {
    True -> []
    False ->
      case bit_array.byte_size(framer.buffer) {
        0 -> []
        _ -> [InvalidTrailingBytes(framer.buffer)]
      }
  }
}

fn extract_frames(
  bytes: BitArray,
  max_frame_bytes: Int,
  acc: List(FramerResult),
) -> #(BitArray, List(FramerResult), Bool) {
  case find_newline(bytes, 0) {
    None -> {
      let size = bit_array.byte_size(bytes)
      case size > max_frame_bytes {
        True -> #(
          <<>>,
          list.reverse([FrameOversized(size, max_frame_bytes), ..acc]),
          True,
        )
        False -> #(bytes, list.reverse(acc), False)
      }
    }
    Some(idx) -> {
      let assert Ok(line) = bit_array.slice(bytes, 0, idx)
      let total_len = bit_array.byte_size(bytes)
      let assert Ok(rest) = bit_array.slice(bytes, idx + 1, total_len - idx - 1)
      let clean_line = strip_trailing_cr(line)
      let size = bit_array.byte_size(clean_line)
      let res = case size > max_frame_bytes {
        True -> FrameOversized(size, max_frame_bytes)
        False -> Frame(clean_line)
      }
      extract_frames(rest, max_frame_bytes, [res, ..acc])
    }
  }
}

fn discard_oversized_tail(
  dropping: Bool,
  chunk: BitArray,
) -> #(BitArray, Bool) {
  case dropping {
    False -> #(chunk, False)
    True ->
      case find_newline(chunk, 0) {
        None -> #(<<>>, True)
        Some(idx) -> {
          let total_len = bit_array.byte_size(chunk)
          let assert Ok(rest) =
            bit_array.slice(chunk, idx + 1, total_len - idx - 1)
          #(rest, False)
        }
      }
  }
}

fn find_newline(bytes: BitArray, offset: Int) -> Option(Int) {
  case bytes {
    <<10, _:bytes>> -> Some(offset)
    <<_, rest:bytes>> -> find_newline(rest, offset + 1)
    _ -> None
  }
}

fn strip_trailing_cr(line: BitArray) -> BitArray {
  let len = bit_array.byte_size(line)
  case len > 0 {
    True -> {
      let last_idx = len - 1
      case bit_array.slice(line, last_idx, 1) {
        Ok(<<13>>) -> {
          let assert Ok(trimmed) = bit_array.slice(line, 0, last_idx)
          trimmed
        }
        _ -> line
      }
    }
    False -> line
  }
}

// Dedicated serialized writer actor

type WriterMessage {
  WriteBytes(bytes: BitArray, reply: Subject(Result(Nil, String)))
  CloseWriter(reply: Subject(Nil))
  OwnerDown
}

pub opaque type Writer {
  Writer(subject: Subject(WriterMessage), pid: Pid, timeout_ms: Int)
}

/// Why a write did not complete.
pub type WriteError {
  /// The sink reported this failure.
  SinkFailed(reason: String)
  /// The sink did not finish within the write timeout. The writer has been
  /// stopped, so every later write fails with `WriterStopped` at once.
  WriteTimedOut
  /// The writer is not running.
  WriterStopped
}

/// Starts a process that runs `sink` for one write at a time. Every write
/// waits at most `timeout_ms` for the sink. The writer is not linked to its
/// caller: it stops when the calling process exits, and a write that times
/// out stops it.
pub fn start_writer(
  sink: fn(BitArray) -> Result(Nil, String),
  timeout_ms: Int,
) -> Result(Writer, actor.StartError) {
  let owner = process.self()
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let monitor = process.monitor(owner)
      actor.initialised(Nil)
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_specific_monitor(monitor, fn(_) { OwnerDown }),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(fn(_state, msg) {
      case msg {
        WriteBytes(bytes, reply) -> {
          let res = sink(bytes)
          process.send(reply, res)
          actor.continue(Nil)
        }
        CloseWriter(reply) -> {
          process.send(reply, Nil)
          actor.stop()
        }
        OwnerDown -> actor.stop()
      }
    })

  case actor.start(builder) {
    Ok(started) -> {
      // Stopping the writer after a stalled write must not take its owner
      // with it; the writer watches the owner through its monitor instead.
      process.unlink(started.pid)
      Ok(Writer(started.data, started.pid, timeout_ms))
    }
    Error(err) -> Error(err)
  }
}

/// Writes `bytes` and waits at most the writer's timeout for the sink.
/// The wait is the back-pressure a slow reader puts on the producer. When it
/// runs out the output is treated as broken: the writer is stopped, because
/// a sink that is stuck in a write cannot serve the writes behind it.
pub fn write_bytes(writer: Writer, bytes: BitArray) -> Result(Nil, WriteError) {
  let Writer(subject, pid, timeout_ms) = writer
  let monitor = process.monitor(pid)
  let reply = process.new_subject()
  process.send(subject, WriteBytes(bytes, reply))
  let outcome =
    process.new_selector()
    |> process.select_map(reply, result.map_error(_, SinkFailed))
    |> process.select_specific_monitor(monitor, fn(_) { Error(WriterStopped) })
    |> process.selector_receive(timeout_ms)
  process.demonitor_process(monitor)
  case outcome {
    Ok(written) -> written
    Error(Nil) -> {
      process.kill(pid)
      Error(WriteTimedOut)
    }
  }
}

/// Stops the writer after the writes already sent to it, waiting at most the
/// writer's timeout before stopping it regardless.
pub fn stop_writer(writer: Writer) -> Nil {
  let Writer(subject, pid, timeout_ms) = writer
  let monitor = process.monitor(pid)
  let reply = process.new_subject()
  process.send(subject, CloseWriter(reply))
  let stopped =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(timeout_ms)
  process.demonitor_process(monitor)
  case stopped {
    Ok(Nil) -> Nil
    Error(Nil) -> process.kill(pid)
  }
}
