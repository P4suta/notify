import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/access
import notify/attachment_store
import notify/config.{type Config}
import notify/delivery
import notify/delivery/postgres as delivery_postgres
import notify/delivery/sqlite as delivery_sqlite
import notify/identity
import notify/identity/postgres as identity_postgres
import notify/identity/sqlite as identity_sqlite
import notify/runtime
import notify/server
import notify/storage
import notify/storage/postgres as storage_postgres
import notify/storage/sqlite as storage_sqlite
import notify/webpush
import notify/webpush/postgres as webpush_postgres
import notify/webpush/sqlite as webpush_sqlite
import postgleam
import postgleam/decode

pub type Level {
  Pass
  Info
  Warning
  Failure
}

pub type Diagnostic {
  Diagnostic(
    level: Level,
    component: String,
    detail: String,
    remediation: Option(String),
  )
}

/// Run dependency checks without starting the HTTP listener. All diagnostics
/// are returned so an operator can fix every reported problem in one pass.
pub fn run(configuration: Config) -> List(Diagnostic) {
  let runtime.Clock(now) = runtime.system_clock()
  static_checks(configuration)
  |> list.append(database_checks(configuration))
  |> list.append(attachment_checks(configuration))
  |> list.append(delivery_checks(configuration))
  |> list.append(webpush_checks(configuration))
  |> list.append(tls_checks(configuration))
  |> list.append([clock_for_configuration(configuration, now())])
}

pub fn static_checks(configuration: Config) -> List(Diagnostic) {
  [
    passed("config", "typed configuration is valid"),
    bind_check(configuration),
    base_url_check(configuration),
    cluster_check(configuration),
    trusted_proxy_check(configuration),
    optional_check(
      "TLS",
      !string.is_empty(configuration.tls_certificate),
      "certificate and private key are configured",
      "disabled; terminate TLS at a trusted reverse proxy or configure tls.certificate and tls.key",
    ),
    optional_check(
      "Web Push",
      !string.is_empty(configuration.webpush_public_key),
      "VAPID key pair and subscriber identity are configured",
      "disabled; run `notify webpush keys` to enable browser push",
    ),
    optional_check(
      "mobile relay",
      !string.is_empty(configuration.relay_url),
      "privacy-preserving upstream relay is configured",
      "disabled",
    ),
  ]
}

pub fn clock_check(local_time: Int, reference_time: Option(Int)) -> Diagnostic {
  case reference_time {
    None ->
      informational(
        "clock",
        "local Unix time is "
          <> int.to_string(local_time)
          <> "; external reference unavailable, so skew was not measured",
      )
    Some(reference_time) -> {
      let skew = int.absolute_value(local_time - reference_time)
      case skew > 30 {
        True ->
          failed(
            "clock",
            "Notify and PostgreSQL clocks differ by "
              <> int.to_string(skew)
              <> " seconds",
            "synchronise the Notify host and PostgreSQL host with NTP",
          )
        False ->
          passed(
            "clock",
            "Notify and PostgreSQL clocks differ by "
              <> int.to_string(skew)
              <> " seconds",
          )
      }
    }
  }
}

pub fn has_failures(checks: List(Diagnostic)) -> Bool {
  list.any(checks, fn(check) { check.level == Failure })
}

pub fn render(check: Diagnostic) -> String {
  level_name(check.level)
  <> " "
  <> check.component
  <> ": "
  <> check.detail
  <> case check.remediation {
    None -> ""
    Some(remediation) -> "\n  FIX " <> remediation
  }
}

fn bind_check(configuration: Config) -> Diagnostic {
  case loopback(configuration.bind) {
    True -> passed("bind policy", "loopback listener " <> configuration.bind)
    False ->
      passed(
        "bind policy",
        "external listener "
          <> configuration.bind
          <> " is protected by the setup gate",
      )
  }
}

fn base_url_check(configuration: Config) -> Diagnostic {
  case configuration.base_url {
    Some(_) -> passed("base URL", "explicit public URL is configured")
    None -> informational("base URL", "derived from the loopback listener")
  }
}

fn cluster_check(configuration: Config) -> Diagnostic {
  case configuration.cluster_enabled {
    True ->
      passed(
        "cluster",
        "PostgreSQL durable event log and shared attachments are configured",
      )
    False -> informational("cluster", "disabled; this node runs independently")
  }
}

fn trusted_proxy_check(configuration: Config) -> Diagnostic {
  case list.length(configuration.trusted_proxies) {
    0 ->
      informational(
        "trusted proxy",
        "none; Forwarded and X-Forwarded-For headers will be ignored",
      )
    count ->
      passed(
        "trusted proxy",
        int.to_string(count) <> " exact proxy address(es) configured",
      )
  }
}

fn optional_check(
  component: String,
  configured: Bool,
  configured_detail: String,
  disabled_detail: String,
) -> Diagnostic {
  case configured {
    True -> passed(component, configured_detail)
    False -> informational(component, disabled_detail)
  }
}

fn database_checks(configuration: Config) -> List(Diagnostic) {
  case open_message_storage(configuration) {
    Error(error) -> [
      failed(
        "database",
        storage_error(error),
        database_remediation(configuration),
      ),
      failed(
        "migrations",
        "schema could not be inspected",
        "restore database connectivity, then run `notify db migrate`",
      ),
    ]
    Ok(messages) ->
      case messages.health() {
        Error(error) -> [
          failed(
            "database",
            storage_error(error),
            database_remediation(configuration),
          ),
        ]
        Ok(_) -> [
          passed("database", database_name(configuration) <> " is writable"),
          passed("migrations", "message schema is current"),
          ..identity_checks(configuration)
        ]
      }
  }
}

fn identity_checks(configuration: Config) -> List(Diagnostic) {
  case open_identity(configuration) {
    Error(error) -> [
      failed(
        "identity",
        identity_error(error),
        "run `notify db migrate`; if this persists, restore a verified backup",
      ),
    ]
    Ok(store) ->
      case store.setup_required(), access.managed(store) {
        Ok(required), Ok(_) -> [
          passed("identity", "identity schema and Argon2id are available"),
          informational("setup gate", case required {
            True -> "setup is required before non-health requests are served"
            False -> "setup is complete"
          }),
        ]
        Error(error), _ -> [
          failed(
            "identity",
            identity_error(error),
            "run `notify db migrate`; if this persists, restore a verified backup",
          ),
        ]
        _, Error(_) -> [
          failed(
            "identity",
            "Argon2id password subsystem is unavailable",
            "install the platform build dependencies and rebuild Notify",
          ),
        ]
      }
  }
}

fn attachment_checks(configuration: Config) -> List(Diagnostic) {
  case server.open_attachment_store(configuration) {
    Error(error) -> [
      failed(
        "attachments",
        attachment_error(error),
        attachment_remediation(configuration),
      ),
    ]
    Ok(store) ->
      case store.health() {
        Ok(_) -> [
          passed(
            "attachments",
            attachment_name(configuration) <> " is readable and writable",
          ),
        ]
        Error(error) -> [
          failed(
            "attachments",
            attachment_error(error),
            attachment_remediation(configuration),
          ),
        ]
      }
  }
}

fn delivery_checks(configuration: Config) -> List(Diagnostic) {
  let opened = case configuration.database_backend {
    config.SQLite -> delivery_sqlite.start(configuration.database_path)
    config.PostgreSQL ->
      delivery_postgres.start(server.postgres_config(configuration))
  }
  case opened {
    Error(error) -> [
      failed(
        "delivery outbox",
        delivery_error(error),
        database_remediation(configuration),
      ),
    ]
    Ok(store) ->
      case store.health() {
        Ok(_) -> [passed("delivery outbox", "schema is current and writable")]
        Error(error) -> [
          failed(
            "delivery outbox",
            delivery_error(error),
            database_remediation(configuration),
          ),
        ]
      }
  }
}

fn webpush_checks(configuration: Config) -> List(Diagnostic) {
  case string.is_empty(configuration.webpush_public_key) {
    True -> []
    False -> {
      let opened = case configuration.database_backend {
        config.SQLite ->
          webpush_sqlite.start(
            configuration.database_path,
            max_endpoints_per_ip: 10,
          )
        config.PostgreSQL ->
          webpush_postgres.start(
            server.postgres_config(configuration),
            max_endpoints_per_ip: 10,
          )
      }
      case opened {
        Error(error) -> [
          failed(
            "Web Push storage",
            webpush_error(error),
            database_remediation(configuration),
          ),
        ]
        Ok(store) ->
          case store.health() {
            Ok(_) -> [
              passed("Web Push storage", "schema is current and writable"),
            ]
            Error(error) -> [
              failed(
                "Web Push storage",
                webpush_error(error),
                database_remediation(configuration),
              ),
            ]
          }
      }
    }
  }
}

fn tls_checks(configuration: Config) -> List(Diagnostic) {
  case string.is_empty(configuration.tls_certificate) {
    True -> []
    False -> [
      readable_check("TLS certificate", configuration.tls_certificate),
      readable_check("TLS private key", configuration.tls_key),
    ]
  }
}

fn readable_check(component: String, path: String) -> Diagnostic {
  case read_file(path) {
    Ok(contents) ->
      case string.is_empty(contents) {
        True ->
          failed(
            component,
            "configured file is empty",
            "replace " <> path <> " with a readable non-empty PEM file",
          )
        False -> passed(component, "configured PEM file is readable")
      }
    Error(_) ->
      failed(
        component,
        "configured file cannot be read",
        "grant the Notify process read permission to " <> path,
      )
  }
}

fn clock_for_configuration(
  configuration: Config,
  local_time: Int,
) -> Diagnostic {
  case configuration.database_backend {
    config.SQLite -> clock_check(local_time, None)
    config.PostgreSQL ->
      case postgres_clock(configuration) {
        Ok(reference) -> clock_check(local_time, Some(reference))
        Error(_) ->
          failed(
            "clock",
            "PostgreSQL time could not be read",
            "restore database connectivity, then rerun `notify doctor`",
          )
      }
  }
}

fn postgres_clock(configuration: Config) -> Result(Int, Nil) {
  use connection <- result.try(
    postgleam.connect(server.postgres_config(configuration))
    |> result.map_error(fn(_) { Nil }),
  )
  let queried =
    postgleam.query_one(
      connection,
      "SELECT EXTRACT(EPOCH FROM clock_timestamp())::bigint",
      [],
      {
        use timestamp <- decode.element(0, decode.int)
        decode.success(timestamp)
      },
    )
    |> result.map_error(fn(_) { Nil })
  postgleam.disconnect(connection)
  queried
}

fn open_message_storage(
  configuration: Config,
) -> Result(storage.Storage, storage.Error) {
  case configuration.database_backend {
    config.SQLite -> storage_sqlite.start(configuration.database_path)
    config.PostgreSQL ->
      storage_postgres.start(
        server.postgres_config(configuration),
        configuration.node_id,
      )
      |> result.map(fn(adapter) {
        let storage_postgres.Adapter(storage:, ..) = adapter
        storage
      })
  }
}

fn open_identity(
  configuration: Config,
) -> Result(identity.Store, identity.Error) {
  case configuration.database_backend {
    config.SQLite -> identity_sqlite.open_store(configuration.database_path)
    config.PostgreSQL ->
      identity_postgres.open_store(server.postgres_config(configuration))
  }
}

fn database_name(configuration: Config) -> String {
  case configuration.database_backend {
    config.SQLite -> "SQLite (WAL, single-node)"
    config.PostgreSQL -> "PostgreSQL"
  }
}

fn database_remediation(configuration: Config) -> String {
  case configuration.database_backend {
    config.SQLite ->
      "check the database path and parent-directory permissions, then run `notify db status`"
    config.PostgreSQL ->
      "check PostgreSQL address, credentials, TLS policy, and grants, then run `notify db status`"
  }
}

fn attachment_name(configuration: Config) -> String {
  case configuration.attachment_backend {
    config.Filesystem -> "local filesystem"
    config.SharedFilesystem -> "shared filesystem"
    config.PostgreSQLBlob -> "PostgreSQL blob store"
    config.S3Compatible -> "S3-compatible object store"
  }
}

fn attachment_remediation(configuration: Config) -> String {
  case configuration.attachment_backend {
    config.Filesystem | config.SharedFilesystem ->
      "check attachments.directory ownership, permissions, and free space"
    config.PostgreSQLBlob -> database_remediation(configuration)
    config.S3Compatible ->
      "check the S3 endpoint, bucket, credentials, region, and bucket policy"
  }
}

fn storage_error(error: storage.Error) -> String {
  case error {
    storage.Unavailable(detail)
    | storage.Conflict(detail)
    | storage.Corrupt(detail)
    | storage.UnsupportedSchema(detail) -> detail
    storage.MigrationRequired(version) ->
      "migration " <> int.to_string(version) <> " is required"
  }
}

fn identity_error(error: identity.Error) -> String {
  case error {
    identity.Unavailable(detail)
    | identity.Conflict(detail)
    | identity.Corrupt(detail) -> detail
    identity.NotFound -> "identity record was not found"
    identity.InvalidSetupToken -> "setup token is invalid"
    identity.SetupAlreadyComplete -> "setup is already complete"
  }
}

fn attachment_error(error: attachment_store.Error) -> String {
  case error {
    attachment_store.TooLarge(limit, actual) ->
      "object size "
      <> int.to_string(actual)
      <> " exceeds "
      <> int.to_string(limit)
    attachment_store.QuotaExceeded(limit) ->
      "quota is exhausted at " <> int.to_string(limit) <> " bytes"
    attachment_store.NotFound -> "object was not found"
    attachment_store.InvalidRange -> "byte range is invalid"
    attachment_store.Unavailable(detail) -> detail
  }
}

fn delivery_error(error: delivery.Error) -> String {
  case error {
    delivery.NotFound -> "delivery job was not found"
    delivery.Conflict -> "delivery job conflicts with an existing record"
    delivery.LeaseLost -> "delivery worker lease was lost"
    delivery.Unavailable(detail) -> detail
  }
}

fn webpush_error(error: webpush.Error) -> String {
  case error {
    webpush.InvalidSubscription -> "subscription is invalid"
    webpush.UnknownEndpoint -> "push endpoint is not allowed"
    webpush.TooManyTopics -> "subscription topic limit was exceeded"
    webpush.TooManySubscriptions -> "subscriber endpoint limit was exceeded"
    webpush.NotFound -> "subscription was not found"
    webpush.Conflict -> "subscription conflicts with an existing record"
    webpush.Unavailable(detail) -> detail
  }
}

fn loopback(bind: String) -> Bool {
  list.contains(["localhost", "127.0.0.1", "::1"], bind)
}

fn passed(component: String, detail: String) -> Diagnostic {
  Diagnostic(Pass, component, detail, None)
}

fn informational(component: String, detail: String) -> Diagnostic {
  Diagnostic(Info, component, detail, None)
}

fn failed(
  component: String,
  detail: String,
  remediation: String,
) -> Diagnostic {
  Diagnostic(Failure, component, detail, Some(remediation))
}

fn level_name(level: Level) -> String {
  case level {
    Pass -> "PASS"
    Info -> "INFO"
    Warning -> "WARN"
    Failure -> "FAIL"
  }
}

@external(erlang, "notify_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)
