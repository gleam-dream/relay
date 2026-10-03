//// Newline framing and a serialized writer for stdio transports.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

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
}

pub opaque type Writer {
  Writer(subject: Subject(WriterMessage))
}

pub fn start_writer(
  sink: fn(BitArray) -> Result(Nil, String),
) -> Result(Writer, actor.StartError) {
  let builder =
    actor.new(Nil)
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
      }
    })

  case actor.start(builder) {
    Ok(started) -> Ok(Writer(started.data))
    Error(err) -> Error(err)
  }
}

pub fn write_bytes(writer: Writer, bytes: BitArray) -> Result(Nil, String) {
  let Writer(subj) = writer
  process.call(subj, waiting: 5000, sending: fn(reply) {
    WriteBytes(bytes, reply)
  })
}

pub fn stop_writer(writer: Writer) -> Nil {
  let Writer(subj) = writer
  process.call(subj, waiting: 5000, sending: CloseWriter)
}
