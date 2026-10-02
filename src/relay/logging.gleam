//// MCP logging severity levels and their wire names.
////
//// `parse_level` reads a level name, `level_name` renders one, and `permits`
//// compares a message level with a threshold. The server reads the threshold a
//// request supplies in its metadata with this module. Relay does not implement
//// `logging/setLevel`.

/// A protocol logging threshold supplied in request metadata.
pub type LogLevel {
  Debug
  Info
  Notice
  Warning
  ErrorLevel
  Critical
  Alert
  Emergency
}

/// Returns whether a message meets the configured threshold.
pub fn permits(threshold: LogLevel, message: LogLevel) -> Bool {
  severity(message) >= severity(threshold)
}

pub fn level_name(level: LogLevel) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Notice -> "notice"
    Warning -> "warning"
    ErrorLevel -> "error"
    Critical -> "critical"
    Alert -> "alert"
    Emergency -> "emergency"
  }
}

pub fn parse_level(raw: String) -> Result(LogLevel, Nil) {
  case raw {
    "debug" -> Ok(Debug)
    "info" -> Ok(Info)
    "notice" -> Ok(Notice)
    "warning" -> Ok(Warning)
    "error" -> Ok(ErrorLevel)
    "critical" -> Ok(Critical)
    "alert" -> Ok(Alert)
    "emergency" -> Ok(Emergency)
    _ -> Error(Nil)
  }
}

fn severity(level: LogLevel) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Notice -> 2
    Warning -> 3
    ErrorLevel -> 4
    Critical -> 5
    Alert -> 6
    Emergency -> 7
  }
}
