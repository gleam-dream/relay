import relay/server.{type Server}

/// Streamable HTTP transport options.
pub type HttpOptions {
  HttpOptions(port: Int, host: String)
}

/// Starts a Streamable HTTP server.
/// Deferred to Wave 3: Streamable HTTP.
pub fn start_http_server(
  _server: Server(context),
  _options: HttpOptions,
) -> Result(Nil, String) {
  todo as "wave 3: Streamable HTTP"
}
