import gleam/option
import notify/config
import notify/http3_listener

pub fn startup_policy_covers_auto_required_and_off_test() {
  assert http3_listener.startup_policy(config.Http3Off, True, True)
    == http3_listener.DoNotStart(http3_listener.Disabled)
  assert http3_listener.startup_policy(config.Http3Auto, False, True)
    == http3_listener.DoNotStart(http3_listener.TlsNotConfigured)
  assert http3_listener.startup_policy(config.Http3Auto, True, False)
    == http3_listener.ContinueDegraded(http3_listener.UnsupportedRuntime)
  assert http3_listener.startup_policy(config.Http3Auto, True, True)
    == http3_listener.StartOptional
  assert http3_listener.startup_policy(config.Http3Required, False, True)
    == http3_listener.FailStartup(http3_listener.TlsNotConfigured)
  assert http3_listener.startup_policy(config.Http3Required, True, False)
    == http3_listener.FailStartup(http3_listener.UnsupportedRuntime)
  assert http3_listener.startup_policy(config.Http3Required, True, True)
    == http3_listener.StartRequired
}

pub fn off_mode_never_advertises_http3_test() {
  let configuration =
    config.Config(..config.defaults(), http3_mode: config.Http3Off)
  let assert Ok(started) =
    http3_listener.start(configuration, fn(_, _) { True })
  let runtime = http3_listener.runtime(started)
  let assert http3_listener.Snapshot(
    mode: config.Http3Off,
    state: http3_listener.Off,
    udp_port: option.None,
    ..,
  ) = http3_listener.snapshot(runtime)
  assert http3_listener.alt_svc(runtime) == "clear"
  assert http3_listener.readiness(runtime)
  assert http3_listener.probe(runtime) == http3_listener.ProbeNotApplicable
  http3_listener.stop(started)
}

pub fn only_a_ready_listener_is_advertised_test() {
  assert http3_listener.alt_svc_value(http3_listener.Ready, option.Some(443))
    == "h3=\":443\"; ma=86400"
  assert http3_listener.alt_svc_value(http3_listener.Degraded, option.Some(443))
    == "clear"
  assert http3_listener.alt_svc_value(http3_listener.Ready, option.None)
    == "clear"
  assert http3_listener.reason_string(http3_listener.StartingListener)
    == "starting"
  assert http3_listener.reason_string(http3_listener.Listening) == "listening"
  assert http3_listener.probe_string(http3_listener.ProbeSucceeded) == "healthy"
  assert http3_listener.probe_string(http3_listener.ProbeFailed)
    == "unavailable"
}

pub fn required_mode_fails_closed_without_tls_test() {
  let configuration =
    config.Config(..config.defaults(), http3_mode: config.Http3Required)
  assert http3_listener.start(configuration, fn(_, _) { True })
    == Error(http3_listener.RequiredUnavailable(http3_listener.TlsNotConfigured))
}

pub fn auto_mode_records_invalid_tls_material_without_stopping_tcp_policy_test() {
  let configuration =
    config.Config(
      ..config.defaults(),
      base_url: option.Some("https://localhost:2586"),
      tls_certificate: "build/packages/http3/test/fixtures/server.pem",
      tls_key: "build/packages/http3/test/fixtures/server.pem",
      http3_mode: config.Http3Auto,
    )
  let assert Ok(started) =
    http3_listener.start(configuration, fn(_, _) { True })
  let runtime = http3_listener.runtime(started)
  let assert http3_listener.Snapshot(
    state: http3_listener.Degraded,
    reason: http3_listener.InvalidPrivateKey,
    ..,
  ) = http3_listener.snapshot(runtime)
  assert http3_listener.alt_svc(runtime) == "clear"
  assert http3_listener.readiness(runtime)
  http3_listener.stop(started)
}

pub fn required_mode_fails_closed_for_invalid_tls_material_test() {
  let configuration =
    config.Config(
      ..config.defaults(),
      base_url: option.Some("https://localhost:2586"),
      tls_certificate: "build/packages/http3/test/fixtures/server.pem",
      tls_key: "build/packages/http3/test/fixtures/server.pem",
      http3_mode: config.Http3Required,
    )
  assert http3_listener.start(configuration, fn(_, _) { True })
    == Error(http3_listener.RequiredUnavailable(
      http3_listener.InvalidPrivateKey,
    ))
}
