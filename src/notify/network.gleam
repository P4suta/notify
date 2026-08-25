/// Configures outbound TCP clients for latency-sensitive request/response
/// protocols such as PostgreSQL. Existing Erlang connect defaults are kept.
pub fn configure_tcp_clients() -> Nil {
  configure_tcp_clients_ffi()
}

pub fn tcp_nodelay_enabled() -> Bool {
  tcp_nodelay_enabled_ffi()
}

@external(erlang, "notify_ffi", "configure_tcp_clients")
fn configure_tcp_clients_ffi() -> Nil

@external(erlang, "notify_ffi", "tcp_nodelay_enabled")
fn tcp_nodelay_enabled_ffi() -> Bool
