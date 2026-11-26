//// An inbound JSON-RPC frame decoded once: the admission the reducer acts
//// on and the correlation the frame carries. Transports build one with
//// `decode`, or from the decode an HTTP endpoint already made for routing,
//// and the frame is never parsed again.

import gleam/option.{type Option}
import relay/internal/carrier
import relay/internal/protocol/v2026_07_28 as v2026
import sinal/correlation.{type Correlation}

pub opaque type Frame {
  Frame(admission: v2026.Admission, correlation: Option(Correlation))
}

/// Decodes and admits `bytes`.
pub fn decode(bytes: BitArray) -> Frame {
  from_decoded(v2026.decode(bytes))
}

/// The frame of a decode made elsewhere.
pub fn from_decoded(decoded: v2026.Decoded) -> Frame {
  Frame(decoded.admission, option.then(decoded.correlation, carrier.parse))
}

pub fn admission(frame: Frame) -> v2026.Admission {
  frame.admission
}

/// The valid correlation the frame carries in `params._meta`, if any.
pub fn correlation(frame: Frame) -> Option(Correlation) {
  frame.correlation
}
