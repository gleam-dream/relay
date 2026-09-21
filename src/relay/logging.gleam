/// Logging level configuration.
pub type LogLevel {
  Debug
  Info
  Notice
  Warning
  Error
  Critical
  Alert
  Emergency
}

/// Sets the logging level.
/// Deferred to Wave 2: Complete modern server core.
pub fn set_level(_level: LogLevel) -> Nil {
  todo as "wave 2: Complete modern server core"
}
