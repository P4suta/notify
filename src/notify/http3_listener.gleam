//// HTTP/3 listener lifecycle, bounded telemetry, and Alt-Svc policy.
////
//// The manager owns the QUIC listener while a separate acceptor blocks in
//// `http3/server.accept`. A failed listener is removed from advertisement
//// immediately and retried without interrupting the TCP compatibility path.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/uri
import http3
import http3/address
import http3/client as h3_client
import http3/server as h3_server
import notify/config

const keepalive_milliseconds = 20_000

const retry_milliseconds = 1000

const stream_buffer_bytes = 1_048_576

const call_timeout_milliseconds = 5000

/// A non-secret operational reason suitable for health output.
pub type Reason {
  Disabled
  StartingListener
  Listening
  TlsNotConfigured
  UnsupportedRuntime
  CertificateUnreadable
  KeyUnreadable
  InvalidCertificate
  InvalidPrivateKey
  InvalidBindAddress
  UdpBindFailed
  ListenerFailed
  LoopbackProbeFailed
}

/// Current UDP listener state.
pub type ListenerState {
  Off
  Starting
  Ready
  Degraded
}

/// Pure startup decision used by configuration checks and lifecycle tests.
pub type StartupPolicy {
  DoNotStart(Reason)
  StartOptional
  StartRequired
  ContinueDegraded(Reason)
  FailStartup(Reason)
}

/// A redacted, finite status and telemetry snapshot.
pub type Snapshot {
  Snapshot(
    mode: config.Http3Mode,
    state: ListenerState,
    reason: Reason,
    udp_port: Option(Int),
    accepted_streams: Int,
    active_streams: Int,
    completed_streams: Int,
    failed_streams: Int,
    listener_restarts: Int,
    probe_successes: Int,
    probe_failures: Int,
    last_probe_succeeded: Option(Bool),
  )
}

/// Result of a certificate-verified HTTP/3 request to the local UDP listener.
pub type ProbeResult {
  ProbeNotApplicable
  ProbeSucceeded
  ProbeFailed
}

type Probe {
  Probe(
    client: h3_client.Client,
    address: address.Address,
    hostname: String,
    port: Int,
  )
}

/// A shareable status handle used by request routing and health endpoints.
pub opaque type Runtime {
  Runtime(subject: Subject(Command), probe: Option(Probe))
}

/// A running listener manager.
pub opaque type Started {
  Started(pid: Pid, runtime: Runtime)
}

/// A typed startup failure with no certificate, key, peer, or backend text.
pub type StartError {
  RequiredUnavailable(Reason)
  ManagerStartFailed(actor.StartError)
}

type Prepared {
  Prepared(configuration: h3_server.Configuration, port: Int, probe: Probe)
}

type State {
  State(
    subject: Subject(Command),
    mode: config.Http3Mode,
    prepared: Option(Prepared),
    listener: Option(h3_server.Listener),
    handler: fn(Runtime, h3_server.Request) -> Bool,
    snapshot: Snapshot,
    retry_scheduled: Bool,
  )
}

type Command {
  Inspect(Subject(Snapshot))
  Accepted(h3_server.Request)
  StreamFinished(Bool)
  ProbeFinished(Bool)
  ListenerStopped
  Retry
  Stop(Subject(Nil))
}

/// Decide whether this process may, must, or must not start HTTP/3.
pub fn startup_policy(
  mode: config.Http3Mode,
  tls_configured: Bool,
  runtime_supported: Bool,
) -> StartupPolicy {
  case mode, tls_configured, runtime_supported {
    config.Http3Off, _, _ -> DoNotStart(Disabled)
    config.Http3Auto, False, _ -> DoNotStart(TlsNotConfigured)
    config.Http3Auto, True, False -> ContinueDegraded(UnsupportedRuntime)
    config.Http3Auto, True, True -> StartOptional
    config.Http3Required, False, _ -> FailStartup(TlsNotConfigured)
    config.Http3Required, True, False -> FailStartup(UnsupportedRuntime)
    config.Http3Required, True, True -> StartRequired
  }
}

/// Start a lifecycle manager and, when policy permits, the UDP listener.
///
/// The handler runs once per accepted HTTP/3 stream and returns whether it
/// completed successfully. Auto mode remains available in a degraded state
/// when listener preparation or binding fails. Required mode fails closed.
pub fn start(
  configuration: config.Config,
  handler: fn(Runtime, h3_server.Request) -> Bool,
) -> Result(Started, StartError) {
  let tls_configured =
    !string.is_empty(string.trim(configuration.tls_certificate))
    && !string.is_empty(string.trim(configuration.tls_key))
  let policy =
    startup_policy(
      configuration.http3_mode,
      tls_configured,
      http3.is_supported(),
    )
  case policy {
    FailStartup(reason) -> Error(RequiredUnavailable(reason))
    DoNotStart(reason) ->
      start_manager(
        configuration.http3_mode,
        None,
        handler,
        initial_snapshot(configuration.http3_mode, Off, reason),
        False,
      )
    ContinueDegraded(reason) ->
      start_manager(
        configuration.http3_mode,
        None,
        handler,
        initial_snapshot(configuration.http3_mode, Degraded, reason),
        False,
      )
    StartOptional ->
      case prepare(configuration) {
        Ok(prepared) ->
          start_manager(
            configuration.http3_mode,
            Some(prepared),
            handler,
            initial_snapshot(
              configuration.http3_mode,
              Starting,
              StartingListener,
            ),
            False,
          )
        Error(reason) ->
          start_manager(
            configuration.http3_mode,
            None,
            handler,
            initial_snapshot(configuration.http3_mode, Degraded, reason),
            False,
          )
      }
    StartRequired -> {
      use prepared <- result.try(
        prepare(configuration) |> result.map_error(RequiredUnavailable),
      )
      use started <- result.try(start_manager(
        configuration.http3_mode,
        Some(prepared),
        handler,
        initial_snapshot(configuration.http3_mode, Starting, StartingListener),
        True,
      ))
      case probe(runtime(started)) {
        ProbeSucceeded -> Ok(started)
        ProbeNotApplicable | ProbeFailed -> {
          stop(started)
          Error(RequiredUnavailable(LoopbackProbeFailed))
        }
      }
    }
  }
}

fn prepare(configuration: config.Config) -> Result(Prepared, Reason) {
  use certificate <- result.try(
    read_binary_file(configuration.tls_certificate)
    |> result.map_error(fn(_) { CertificateUnreadable }),
  )
  use private_key <- result.try(
    read_binary_file(configuration.tls_key)
    |> result.map_error(fn(_) { KeyUnreadable }),
  )
  use bind_address <- result.try(
    bind_address(configuration.bind)
    |> result.map_error(fn(_) { InvalidBindAddress }),
  )
  use probe <- result.try(build_probe(configuration, certificate, bind_address))
  use server_configuration <- result.try(
    h3_server.new(certificate, private_key)
    |> result.map_error(fn(error) {
      case error {
        h3_server.InvalidCertificate -> InvalidCertificate
        h3_server.InvalidPrivateKey -> InvalidPrivateKey
        _ -> InvalidCertificate
      }
    }),
  )
  use server_configuration <- result.try(
    h3_server.with_port(server_configuration, configuration.port)
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  use server_configuration <- result.try(
    h3_server.with_keepalive(server_configuration, keepalive_milliseconds)
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  use server_configuration <- result.try(
    h3_server.with_request_body_limit(
      server_configuration,
      configuration.max_request_bytes,
    )
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  use server_configuration <- result.try(
    h3_server.with_response_body_limit(
      server_configuration,
      int.max(
        configuration.max_request_bytes,
        configuration.attachment_file_size_bytes,
      ),
    )
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  use server_configuration <- result.try(
    h3_server.with_stream_buffer_limit(
      server_configuration,
      stream_buffer_bytes,
    )
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  Ok(Prepared(
    h3_server.with_bind_address(server_configuration, bind_address),
    configuration.port,
    probe,
  ))
}

fn build_probe(
  configuration: config.Config,
  certificate_pem: BitArray,
  bind_address: address.Address,
) -> Result(Probe, Reason) {
  use certificate <- result.try(
    certificate_der_from_pem(certificate_pem)
    |> result.map_error(fn(_) { InvalidCertificate }),
  )
  use hostname <- result.try(
    probe_hostname(configuration)
    |> result.map_error(fn(_) { InvalidBindAddress }),
  )
  use dial_address <- result.try(
    probe_address(bind_address)
    |> result.map_error(fn(_) { InvalidBindAddress }),
  )
  use client <- result.try(
    h3_client.with_timeout(h3_client.new(), 3000)
    |> result.map_error(fn(_) { InvalidCertificate }),
  )
  use client <- result.try(
    h3_client.with_ca_certificate(client, certificate)
    |> result.map_error(fn(_) { InvalidCertificate }),
  )
  Ok(Probe(client, dial_address, hostname, configuration.port))
}

fn probe_hostname(configuration: config.Config) -> Result(String, Nil) {
  case configuration.base_url {
    Some(value) ->
      case uri.parse(value) {
        Ok(uri.Uri(host: Some(host), ..)) if host != "" -> Ok(host)
        _ -> Error(Nil)
      }
    None ->
      case string.lowercase(string.trim(configuration.bind)) {
        "0.0.0.0" -> Ok("127.0.0.1")
        "::" -> Ok("::1")
        host if host != "" -> Ok(host)
        _ -> Error(Nil)
      }
  }
}

fn probe_address(
  value: address.Address,
) -> Result(address.Address, address.Error) {
  case address.to_string(value) {
    "0.0.0.0" -> address.parse("127.0.0.1")
    "::" -> address.parse("::1")
    _ -> Ok(value)
  }
}

fn bind_address(value: String) -> Result(address.Address, address.Error) {
  case string.lowercase(string.trim(value)) {
    "localhost" -> address.parse("127.0.0.1")
    literal -> address.parse(literal)
  }
}

fn start_manager(
  mode: config.Http3Mode,
  prepared: Option(Prepared),
  handler: fn(Runtime, h3_server.Request) -> Bool,
  initial: Snapshot,
  fail_closed: Bool,
) -> Result(Started, StartError) {
  let probe = prepared_probe(prepared)
  let manager =
    actor.new_with_initialiser(call_timeout_milliseconds, fn(subject) {
      let state =
        State(
          subject:,
          mode:,
          prepared:,
          listener: None,
          handler:,
          snapshot: initial,
          retry_scheduled: False,
        )
      case prepared {
        None -> actor.initialised(state) |> actor.returning(subject) |> Ok
        Some(prepared) ->
          case start_listener(state, prepared, subject) {
            Ok(started) ->
              actor.initialised(started) |> actor.returning(subject) |> Ok
            Error(_) if fail_closed ->
              Error("required HTTP/3 listener unavailable")
            Error(reason) -> {
              let degraded = set_degraded(state, reason)
              schedule_retry(subject)
              actor.initialised(State(..degraded, retry_scheduled: True))
              |> actor.returning(subject)
              |> Ok
            }
          }
      }
    })
    |> actor.on_message(handle)
    |> actor.start
  case manager {
    Ok(started) -> Ok(Started(started.pid, Runtime(started.data, probe)))
    Error(_error) if fail_closed -> Error(RequiredUnavailable(UdpBindFailed))
    Error(error) -> Error(ManagerStartFailed(error))
  }
}

fn start_listener(
  state: State,
  prepared: Prepared,
  subject: Subject(Command),
) -> Result(State, Reason) {
  let Prepared(configuration, configured_port, probe) = prepared
  use listener <- result.try(
    h3_server.start(configuration)
    |> result.map_error(fn(_) { UdpBindFailed }),
  )
  let port = case h3_server.port(listener) {
    Ok(port) -> port
    Error(_) -> configured_port
  }
  spawn_acceptor(listener, subject)
  spawn_probe(probe, subject)
  let Snapshot(listener_restarts:, ..) = state.snapshot
  Ok(
    State(
      ..state,
      prepared: Some(Prepared(configuration, port, probe)),
      listener: Some(listener),
      retry_scheduled: False,
      snapshot: Snapshot(
        ..state.snapshot,
        state: Starting,
        reason: StartingListener,
        udp_port: None,
        last_probe_succeeded: None,
        listener_restarts: case state.snapshot.state {
          Starting -> listener_restarts
          _ -> listener_restarts + 1
        },
      ),
    ),
  )
}

fn prepared_probe(prepared: Option(Prepared)) -> Option(Probe) {
  case prepared {
    None -> None
    Some(Prepared(_, _, probe)) -> Some(probe)
  }
}

fn spawn_probe(probe: Probe, subject: Subject(Command)) -> Pid {
  process.spawn(fn() {
    let succeeded = perform_probe(probe) == ProbeSucceeded
    process.send(subject, ProbeFinished(succeeded))
  })
}

fn spawn_acceptor(
  listener: h3_server.Listener,
  subject: Subject(Command),
) -> Pid {
  process.spawn(fn() { accept_loop(listener, subject) })
}

fn accept_loop(listener: h3_server.Listener, subject: Subject(Command)) -> Nil {
  case h3_server.accept(listener) {
    Ok(request) -> {
      process.send(subject, Accepted(request))
      accept_loop(listener, subject)
    }
    Error(_) -> process.send(subject, ListenerStopped)
  }
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Inspect(reply) -> {
      process.send(reply, state.snapshot)
      actor.continue(state)
    }
    Accepted(request) -> {
      let Snapshot(accepted_streams:, active_streams:, ..) = state.snapshot
      let subject = runtime_subject(state)
      let handler = state.handler
      let probe = prepared_probe(state.prepared)
      let _pid =
        process.spawn(fn() {
          let succeeded = handler(Runtime(subject, probe), request)
          process.send(subject, StreamFinished(succeeded))
        })
      actor.continue(
        State(
          ..state,
          snapshot: Snapshot(
            ..state.snapshot,
            accepted_streams: accepted_streams + 1,
            active_streams: active_streams + 1,
          ),
        ),
      )
    }
    StreamFinished(succeeded) -> {
      let Snapshot(active_streams:, completed_streams:, failed_streams:, ..) =
        state.snapshot
      actor.continue(
        State(
          ..state,
          snapshot: Snapshot(
            ..state.snapshot,
            active_streams: int.max(0, active_streams - 1),
            completed_streams: case succeeded {
              True -> completed_streams + 1
              False -> completed_streams
            },
            failed_streams: case succeeded {
              True -> failed_streams
              False -> failed_streams + 1
            },
          ),
        ),
      )
    }
    ProbeFinished(succeeded) -> actor.continue(record_probe(state, succeeded))
    ListenerStopped -> {
      stop_listener(state.listener)
      let degraded =
        set_degraded(State(..state, listener: None), ListenerFailed)
      case state.prepared, state.retry_scheduled {
        Some(_), False -> {
          schedule_retry(runtime_subject(state))
          actor.continue(State(..degraded, retry_scheduled: True))
        }
        _, _ -> actor.continue(degraded)
      }
    }
    Retry ->
      case state.prepared {
        None -> actor.continue(State(..state, retry_scheduled: False))
        Some(prepared) ->
          case
            start_listener(
              State(..state, retry_scheduled: False),
              prepared,
              runtime_subject(state),
            )
          {
            Ok(started) -> actor.continue(started)
            Error(reason) -> {
              schedule_retry(runtime_subject(state))
              actor.continue(
                State(
                  ..set_degraded(state, reason),
                  listener: None,
                  retry_scheduled: True,
                ),
              )
            }
          }
      }
    Stop(reply) -> {
      stop_listener(state.listener)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn runtime_subject(state: State) -> Subject(Command) {
  state.subject
}

fn record_probe(state: State, succeeded: Bool) -> State {
  let Snapshot(probe_successes:, probe_failures:, ..) = state.snapshot
  let counted =
    Snapshot(
      ..state.snapshot,
      probe_successes: case succeeded {
        True -> probe_successes + 1
        False -> probe_successes
      },
      probe_failures: case succeeded {
        True -> probe_failures
        False -> probe_failures + 1
      },
      last_probe_succeeded: Some(succeeded),
    )
  case succeeded, state.listener, prepared_port(state.prepared) {
    True, Some(_), Some(port) ->
      State(
        ..state,
        snapshot: Snapshot(
          ..counted,
          state: Ready,
          reason: Listening,
          udp_port: Some(port),
        ),
      )
    False, _, _ ->
      State(
        ..state,
        snapshot: Snapshot(
          ..counted,
          state: Degraded,
          reason: LoopbackProbeFailed,
          udp_port: None,
        ),
      )
    True, _, _ -> State(..state, snapshot: counted)
  }
}

fn prepared_port(prepared: Option(Prepared)) -> Option(Int) {
  case prepared {
    None -> None
    Some(Prepared(_, port, _)) -> Some(port)
  }
}

fn set_degraded(state: State, reason: Reason) -> State {
  State(
    ..state,
    snapshot: Snapshot(
      ..state.snapshot,
      state: Degraded,
      reason:,
      udp_port: None,
      last_probe_succeeded: None,
    ),
  )
}

fn schedule_retry(subject: Subject(Command)) -> Nil {
  let _pid =
    process.spawn(fn() {
      process.sleep(retry_milliseconds)
      process.send(subject, Retry)
    })
  Nil
}

fn stop_listener(listener: Option(h3_server.Listener)) -> Nil {
  case listener {
    None -> Nil
    Some(listener) -> {
      let _ = h3_server.stop(listener)
      Nil
    }
  }
}

fn initial_snapshot(
  mode: config.Http3Mode,
  state: ListenerState,
  reason: Reason,
) -> Snapshot {
  Snapshot(
    mode:,
    state:,
    reason:,
    udp_port: None,
    accepted_streams: 0,
    active_streams: 0,
    completed_streams: 0,
    failed_streams: 0,
    listener_restarts: 0,
    probe_successes: 0,
    probe_failures: 0,
    last_probe_succeeded: None,
  )
}

/// Return the status handle associated with a started manager.
pub fn runtime(started: Started) -> Runtime {
  started.runtime
}

/// Return the manager process for lifecycle ownership.
pub fn pid(started: Started) -> Pid {
  started.pid
}

/// Read a finite status snapshot.
pub fn snapshot(runtime: Runtime) -> Snapshot {
  let Runtime(subject, _) = runtime
  process.call(subject, call_timeout_milliseconds, Inspect)
}

/// Perform one bounded, certificate-verified HTTP/3 GET against the exact
/// local UDP listener address. The TLS hostname remains the configured public
/// origin, and the result updates redacted listener telemetry.
pub fn probe(runtime: Runtime) -> ProbeResult {
  let Runtime(subject, configured) = runtime
  case configured {
    None -> ProbeNotApplicable
    Some(configured) -> {
      let outcome = perform_probe(configured)
      process.send(subject, ProbeFinished(outcome == ProbeSucceeded))
      // A same-sender call is ordered after the update, so required startup
      // and detailed health never observe a transient pre-probe Ready state.
      let _updated = snapshot(runtime)
      outcome
    }
  }
}

/// Probe an already-running listener described by configuration. This is used
/// by `notify doctor` when its temporary same-port bind finds the service is
/// already running.
pub fn probe_configuration(configuration: config.Config) -> ProbeResult {
  let tls_configured =
    !string.is_empty(string.trim(configuration.tls_certificate))
    && !string.is_empty(string.trim(configuration.tls_key))
  case
    startup_policy(
      configuration.http3_mode,
      tls_configured,
      http3.is_supported(),
    )
  {
    StartOptional | StartRequired ->
      case configured_probe(configuration) {
        Ok(configured) -> perform_probe(configured)
        Error(_) -> ProbeFailed
      }
    _ -> ProbeNotApplicable
  }
}

fn configured_probe(configuration: config.Config) -> Result(Probe, Reason) {
  use certificate <- result.try(
    read_binary_file(configuration.tls_certificate)
    |> result.map_error(fn(_) { CertificateUnreadable }),
  )
  use bind <- result.try(
    bind_address(configuration.bind)
    |> result.map_error(fn(_) { InvalidBindAddress }),
  )
  build_probe(configuration, certificate, bind)
}

fn perform_probe(configured: Probe) -> ProbeResult {
  let Probe(client, address, hostname, port) = configured
  let request =
    request.new()
    |> request.set_scheme(http.Https)
    |> request.set_host(hostname)
    |> request.set_port(port)
    |> request.set_path("/healthz")
    |> request.set_method(http.Get)
    |> request.set_body(<<>>)
  case h3_client.send_to(client, address, request) {
    Ok(response) if response.status == 200 -> ProbeSucceeded
    _ -> ProbeFailed
  }
}

/// Stable redacted probe result for health and doctor output.
pub fn probe_string(result: ProbeResult) -> String {
  case result {
    ProbeNotApplicable -> "not_applicable"
    ProbeSucceeded -> "healthy"
    ProbeFailed -> "unavailable"
  }
}

/// Return the TCP Alt-Svc value for the current listener state.
pub fn alt_svc(runtime: Runtime) -> String {
  let Snapshot(state:, udp_port:, ..) = snapshot(runtime)
  alt_svc_value(state, udp_port)
}

/// Render the RFC 9114 advertisement for a listener snapshot.
pub fn alt_svc_value(state: ListenerState, udp_port: Option(Int)) -> String {
  case state, udp_port {
    Ready, Some(port) -> "h3=\":" <> int.to_string(port) <> "\"; ma=86400"
    _, _ -> "clear"
  }
}

/// Return whether this mode and listener state satisfy readiness.
pub fn readiness(runtime: Runtime) -> Bool {
  case snapshot(runtime) {
    Snapshot(
      mode: config.Http3Required,
      state: Ready,
      last_probe_succeeded: Some(True),
      ..,
    ) -> True
    Snapshot(mode: config.Http3Required, ..) -> False
    _ -> True
  }
}

/// Gracefully stop the UDP listener and manager.
pub fn stop(started: Started) -> Nil {
  let Runtime(subject, _) = started.runtime
  process.call(subject, call_timeout_milliseconds, Stop)
}

/// Stable redacted listener-state name for health and structured logs.
pub fn state_string(state: ListenerState) -> String {
  case state {
    Off -> "off"
    Starting -> "starting"
    Ready -> "ready"
    Degraded -> "degraded"
  }
}

/// Stable redacted reason name for health and structured logs.
pub fn reason_string(reason: Reason) -> String {
  case reason {
    Disabled -> "disabled"
    StartingListener -> "starting"
    Listening -> "listening"
    TlsNotConfigured -> "tls_not_configured"
    UnsupportedRuntime -> "unsupported_runtime"
    CertificateUnreadable -> "certificate_unreadable"
    KeyUnreadable -> "key_unreadable"
    InvalidCertificate -> "invalid_certificate"
    InvalidPrivateKey -> "invalid_private_key"
    InvalidBindAddress -> "invalid_bind_address"
    UdpBindFailed -> "udp_bind_failed"
    ListenerFailed -> "listener_failed"
    LoopbackProbeFailed -> "loopback_probe_failed"
  }
}

@external(erlang, "notify_ffi", "read_binary_file")
fn read_binary_file(path: String) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "certificate_der_from_pem")
fn certificate_der_from_pem(pem: BitArray) -> Result(BitArray, String)
