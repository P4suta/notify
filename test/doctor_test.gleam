import gleam/option.{None, Some}
import gleam/string
import notify/config
import notify/doctor

pub fn clock_check_accepts_small_postgres_skew_test() {
  let check = doctor.clock_check(1000, Some(1012))
  assert check.level == doctor.Pass
  assert check.component == "clock"
  assert string.contains(check.detail, "12 seconds")
  assert check.remediation == None
}

pub fn clock_check_rejects_actionable_postgres_skew_test() {
  let check = doctor.clock_check(1000, Some(1031))
  assert check.level == doctor.Failure
  assert doctor.has_failures([check])
  assert check.remediation
    == Some("synchronise the Notify host and PostgreSQL host with NTP")
}

pub fn sqlite_clock_check_is_explicitly_unverified_test() {
  let check = doctor.clock_check(1000, None)
  assert check.level == doctor.Info
  assert string.contains(check.detail, "external reference unavailable")
  assert !doctor.has_failures([check])
}

pub fn static_checks_describe_cluster_and_optional_services_test() {
  let configured =
    config.Config(
      ..config.defaults(),
      bind: "0.0.0.0",
      base_url: Some("https://notify.example"),
      database_backend: config.PostgreSQL,
      cluster_enabled: True,
      attachment_backend: config.PostgreSQLBlob,
      trusted_proxies: ["127.0.0.1"],
      webpush_public_key: "public",
      webpush_private_key: "private",
      webpush_subscriber: "mailto:admin@example.test",
      relay_url: "https://relay.example",
      relay_token: "secret",
      tls_certificate: "cert.pem",
      tls_key: "key.pem",
    )
  let checks = doctor.static_checks(configured)
  assert list_has(checks, "bind policy", doctor.Pass)
  assert list_has(checks, "base URL", doctor.Pass)
  assert list_has(checks, "cluster", doctor.Pass)
  assert list_has(checks, "trusted proxy", doctor.Pass)
  assert list_has(checks, "HTTP/3", doctor.Pass)
  assert list_has(checks, "Web Push", doctor.Pass)
  assert list_has(checks, "mobile relay", doctor.Pass)
}

fn list_has(
  checks: List(doctor.Diagnostic),
  component: String,
  level: doctor.Level,
) -> Bool {
  case checks {
    [] -> False
    [check, ..rest] ->
      case check.component == component && check.level == level {
        True -> True
        False -> list_has(rest, component, level)
      }
  }
}
