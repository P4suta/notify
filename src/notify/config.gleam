import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import notify/proxy

pub type DatabaseBackend {
  SQLite
  PostgreSQL
}

pub type PostgresSsl {
  SslDisabled
  SslVerified
  SslUnverified
}

pub type AttachmentBackend {
  Filesystem
  SharedFilesystem
  PostgreSQLBlob
  S3Compatible
}

pub type LogFormat {
  HumanLogs
  JsonLogs
}

pub type Config {
  Config(
    bind: String,
    port: Int,
    base_url: Option(String),
    database_backend: DatabaseBackend,
    database_path: String,
    postgres_host: String,
    postgres_port: Int,
    postgres_database: String,
    postgres_username: String,
    postgres_password: String,
    postgres_ssl: PostgresSsl,
    node_id: String,
    retention_seconds: Int,
    max_request_bytes: Int,
    rate_limit_requests: Int,
    rate_limit_subscriptions: Int,
    rate_limit_topic_creations: Int,
    rate_limit_auth_failures: Int,
    rate_limit_attachment_mebibytes: Int,
    rate_limit_attachment_uploads: Int,
    rate_limit_window_seconds: Int,
    dev_open: Bool,
    cluster_enabled: Bool,
    attachment_backend: AttachmentBackend,
    attachment_directory: String,
    attachment_file_size_bytes: Int,
    attachment_total_size_bytes: Int,
    attachment_retention_seconds: Int,
    s3_endpoint: String,
    s3_bucket: String,
    s3_region: String,
    s3_access_key: String,
    s3_secret_key: String,
    s3_path_style: Bool,
    webpush_public_key: String,
    webpush_private_key: String,
    webpush_subscriber: String,
    relay_url: String,
    relay_token: String,
    tls_certificate: String,
    tls_key: String,
    trusted_proxies: List(String),
    log_format: LogFormat,
  )
}

pub type Partial {
  Partial(
    bind: Option(String),
    port: Option(Int),
    base_url: Option(String),
    database_backend: Option(DatabaseBackend),
    database_path: Option(String),
    postgres_host: Option(String),
    postgres_port: Option(Int),
    postgres_database: Option(String),
    postgres_username: Option(String),
    postgres_password: Option(String),
    postgres_ssl: Option(PostgresSsl),
    node_id: Option(String),
    retention_seconds: Option(Int),
    max_request_bytes: Option(Int),
    rate_limit_requests: Option(Int),
    rate_limit_subscriptions: Option(Int),
    rate_limit_topic_creations: Option(Int),
    rate_limit_auth_failures: Option(Int),
    rate_limit_attachment_mebibytes: Option(Int),
    rate_limit_attachment_uploads: Option(Int),
    rate_limit_window_seconds: Option(Int),
    dev_open: Option(Bool),
    cluster_enabled: Option(Bool),
    attachment_backend: Option(AttachmentBackend),
    attachment_directory: Option(String),
    attachment_file_size_bytes: Option(Int),
    attachment_total_size_bytes: Option(Int),
    attachment_retention_seconds: Option(Int),
    s3_endpoint: Option(String),
    s3_bucket: Option(String),
    s3_region: Option(String),
    s3_access_key: Option(String),
    s3_secret_key: Option(String),
    s3_path_style: Option(Bool),
    webpush_public_key: Option(String),
    webpush_private_key: Option(String),
    webpush_subscriber: Option(String),
    relay_url: Option(String),
    relay_token: Option(String),
    tls_certificate: Option(String),
    tls_key: Option(String),
    trusted_proxies: Option(List(String)),
    log_format: Option(LogFormat),
  )
}

pub type Error {
  InvalidPort(Int)
  InvalidRetention(Int)
  InvalidRequestSize(Int)
  InvalidRateLimit
  DevOpenRequiresLoopback
  ActiveActiveRequiresPostgres
  InvalidAttachmentLimits
  PublicAttachmentsRequireBaseUrl
  InvalidBaseUrl(String)
  InvalidPostgresPort(Int)
  MissingClusterNodeId
  ActiveActiveRequiresSharedAttachments
  MissingS3Configuration
  InvalidWebPushConfiguration
  InvalidRelayConfiguration
  InvalidTlsConfiguration
  InvalidTrustedProxy(String)
  InvalidInteger(String, String)
  InvalidBoolean(String, String)
  InvalidToml(String)
  InvalidFlag(String)
}

pub fn defaults() -> Config {
  Config(
    bind: "127.0.0.1",
    port: 8080,
    base_url: None,
    database_backend: SQLite,
    database_path: "data/notify.db",
    postgres_host: "127.0.0.1",
    postgres_port: 5432,
    postgres_database: "notify",
    postgres_username: "notify",
    postgres_password: "",
    postgres_ssl: SslDisabled,
    node_id: "notify-1",
    retention_seconds: 43_200,
    max_request_bytes: 16_777_216,
    rate_limit_requests: 120,
    rate_limit_subscriptions: 30,
    rate_limit_topic_creations: 60,
    rate_limit_auth_failures: 10,
    rate_limit_attachment_mebibytes: 120,
    rate_limit_attachment_uploads: 20,
    rate_limit_window_seconds: 60,
    dev_open: False,
    cluster_enabled: False,
    attachment_backend: Filesystem,
    attachment_directory: "data/attachments",
    attachment_file_size_bytes: 15_728_640,
    attachment_total_size_bytes: 104_857_600,
    attachment_retention_seconds: 10_800,
    s3_endpoint: "",
    s3_bucket: "",
    s3_region: "us-east-1",
    s3_access_key: "",
    s3_secret_key: "",
    s3_path_style: True,
    webpush_public_key: "",
    webpush_private_key: "",
    webpush_subscriber: "",
    relay_url: "",
    relay_token: "",
    tls_certificate: "",
    tls_key: "",
    trusted_proxies: [],
    log_format: HumanLogs,
  )
}

pub fn empty_partial() -> Partial {
  Partial(
    bind: None,
    port: None,
    base_url: None,
    database_backend: None,
    database_path: None,
    postgres_host: None,
    postgres_port: None,
    postgres_database: None,
    postgres_username: None,
    postgres_password: None,
    postgres_ssl: None,
    node_id: None,
    retention_seconds: None,
    max_request_bytes: None,
    rate_limit_requests: None,
    rate_limit_subscriptions: None,
    rate_limit_topic_creations: None,
    rate_limit_auth_failures: None,
    rate_limit_attachment_mebibytes: None,
    rate_limit_attachment_uploads: None,
    rate_limit_window_seconds: None,
    dev_open: None,
    cluster_enabled: None,
    attachment_backend: None,
    attachment_directory: None,
    attachment_file_size_bytes: None,
    attachment_total_size_bytes: None,
    attachment_retention_seconds: None,
    s3_endpoint: None,
    s3_bucket: None,
    s3_region: None,
    s3_access_key: None,
    s3_secret_key: None,
    s3_path_style: None,
    webpush_public_key: None,
    webpush_private_key: None,
    webpush_subscriber: None,
    relay_url: None,
    relay_token: None,
    tls_certificate: None,
    tls_key: None,
    trusted_proxies: None,
    log_format: None,
  )
}

pub fn resolve(
  defaults: Config,
  toml: Partial,
  environment: Partial,
  flags: Partial,
) -> Config {
  Config(
    bind: choose(flags.bind, environment.bind, toml.bind, defaults.bind),
    port: choose(flags.port, environment.port, toml.port, defaults.port),
    base_url: flags.base_url
      |> option.or(environment.base_url)
      |> option.or(toml.base_url)
      |> option.or(defaults.base_url),
    database_backend: choose(
      flags.database_backend,
      environment.database_backend,
      toml.database_backend,
      defaults.database_backend,
    ),
    database_path: choose(
      flags.database_path,
      environment.database_path,
      toml.database_path,
      defaults.database_path,
    ),
    postgres_host: choose(
      flags.postgres_host,
      environment.postgres_host,
      toml.postgres_host,
      defaults.postgres_host,
    ),
    postgres_port: choose(
      flags.postgres_port,
      environment.postgres_port,
      toml.postgres_port,
      defaults.postgres_port,
    ),
    postgres_database: choose(
      flags.postgres_database,
      environment.postgres_database,
      toml.postgres_database,
      defaults.postgres_database,
    ),
    postgres_username: choose(
      flags.postgres_username,
      environment.postgres_username,
      toml.postgres_username,
      defaults.postgres_username,
    ),
    postgres_password: choose(
      flags.postgres_password,
      environment.postgres_password,
      toml.postgres_password,
      defaults.postgres_password,
    ),
    postgres_ssl: choose(
      flags.postgres_ssl,
      environment.postgres_ssl,
      toml.postgres_ssl,
      defaults.postgres_ssl,
    ),
    node_id: choose(
      flags.node_id,
      environment.node_id,
      toml.node_id,
      defaults.node_id,
    ),
    retention_seconds: choose(
      flags.retention_seconds,
      environment.retention_seconds,
      toml.retention_seconds,
      defaults.retention_seconds,
    ),
    max_request_bytes: choose(
      flags.max_request_bytes,
      environment.max_request_bytes,
      toml.max_request_bytes,
      defaults.max_request_bytes,
    ),
    rate_limit_requests: choose(
      flags.rate_limit_requests,
      environment.rate_limit_requests,
      toml.rate_limit_requests,
      defaults.rate_limit_requests,
    ),
    rate_limit_subscriptions: choose(
      flags.rate_limit_subscriptions,
      environment.rate_limit_subscriptions,
      toml.rate_limit_subscriptions,
      defaults.rate_limit_subscriptions,
    ),
    rate_limit_topic_creations: choose(
      flags.rate_limit_topic_creations,
      environment.rate_limit_topic_creations,
      toml.rate_limit_topic_creations,
      defaults.rate_limit_topic_creations,
    ),
    rate_limit_auth_failures: choose(
      flags.rate_limit_auth_failures,
      environment.rate_limit_auth_failures,
      toml.rate_limit_auth_failures,
      defaults.rate_limit_auth_failures,
    ),
    rate_limit_attachment_mebibytes: choose(
      flags.rate_limit_attachment_mebibytes,
      environment.rate_limit_attachment_mebibytes,
      toml.rate_limit_attachment_mebibytes,
      defaults.rate_limit_attachment_mebibytes,
    ),
    rate_limit_attachment_uploads: choose(
      flags.rate_limit_attachment_uploads,
      environment.rate_limit_attachment_uploads,
      toml.rate_limit_attachment_uploads,
      defaults.rate_limit_attachment_uploads,
    ),
    rate_limit_window_seconds: choose(
      flags.rate_limit_window_seconds,
      environment.rate_limit_window_seconds,
      toml.rate_limit_window_seconds,
      defaults.rate_limit_window_seconds,
    ),
    dev_open: choose(
      flags.dev_open,
      environment.dev_open,
      toml.dev_open,
      defaults.dev_open,
    ),
    cluster_enabled: choose(
      flags.cluster_enabled,
      environment.cluster_enabled,
      toml.cluster_enabled,
      defaults.cluster_enabled,
    ),
    attachment_backend: choose(
      flags.attachment_backend,
      environment.attachment_backend,
      toml.attachment_backend,
      defaults.attachment_backend,
    ),
    attachment_directory: choose(
      flags.attachment_directory,
      environment.attachment_directory,
      toml.attachment_directory,
      defaults.attachment_directory,
    ),
    attachment_file_size_bytes: choose(
      flags.attachment_file_size_bytes,
      environment.attachment_file_size_bytes,
      toml.attachment_file_size_bytes,
      defaults.attachment_file_size_bytes,
    ),
    attachment_total_size_bytes: choose(
      flags.attachment_total_size_bytes,
      environment.attachment_total_size_bytes,
      toml.attachment_total_size_bytes,
      defaults.attachment_total_size_bytes,
    ),
    attachment_retention_seconds: choose(
      flags.attachment_retention_seconds,
      environment.attachment_retention_seconds,
      toml.attachment_retention_seconds,
      defaults.attachment_retention_seconds,
    ),
    s3_endpoint: choose(
      flags.s3_endpoint,
      environment.s3_endpoint,
      toml.s3_endpoint,
      defaults.s3_endpoint,
    ),
    s3_bucket: choose(
      flags.s3_bucket,
      environment.s3_bucket,
      toml.s3_bucket,
      defaults.s3_bucket,
    ),
    s3_region: choose(
      flags.s3_region,
      environment.s3_region,
      toml.s3_region,
      defaults.s3_region,
    ),
    s3_access_key: choose(
      flags.s3_access_key,
      environment.s3_access_key,
      toml.s3_access_key,
      defaults.s3_access_key,
    ),
    s3_secret_key: choose(
      flags.s3_secret_key,
      environment.s3_secret_key,
      toml.s3_secret_key,
      defaults.s3_secret_key,
    ),
    s3_path_style: choose(
      flags.s3_path_style,
      environment.s3_path_style,
      toml.s3_path_style,
      defaults.s3_path_style,
    ),
    webpush_public_key: choose(
      flags.webpush_public_key,
      environment.webpush_public_key,
      toml.webpush_public_key,
      defaults.webpush_public_key,
    ),
    webpush_private_key: choose(
      flags.webpush_private_key,
      environment.webpush_private_key,
      toml.webpush_private_key,
      defaults.webpush_private_key,
    ),
    webpush_subscriber: choose(
      flags.webpush_subscriber,
      environment.webpush_subscriber,
      toml.webpush_subscriber,
      defaults.webpush_subscriber,
    ),
    relay_url: choose(
      flags.relay_url,
      environment.relay_url,
      toml.relay_url,
      defaults.relay_url,
    ),
    relay_token: choose(
      flags.relay_token,
      environment.relay_token,
      toml.relay_token,
      defaults.relay_token,
    ),
    tls_certificate: choose(
      flags.tls_certificate,
      environment.tls_certificate,
      toml.tls_certificate,
      defaults.tls_certificate,
    ),
    tls_key: choose(
      flags.tls_key,
      environment.tls_key,
      toml.tls_key,
      defaults.tls_key,
    ),
    trusted_proxies: choose(
      flags.trusted_proxies,
      environment.trusted_proxies,
      toml.trusted_proxies,
      defaults.trusted_proxies,
    ),
    log_format: choose(
      flags.log_format,
      environment.log_format,
      toml.log_format,
      defaults.log_format,
    ),
  )
}

fn choose(
  first: Option(a),
  second: Option(a),
  third: Option(a),
  default: a,
) -> a {
  first
  |> option.or(second)
  |> option.or(third)
  |> option.unwrap(default)
}

pub fn validate(config: Config) -> Result(Config, Error) {
  case config.max_request_bytes < 1, valid_rate_limits(config) {
    True, _ -> Error(InvalidRequestSize(config.max_request_bytes))
    _, False -> Error(InvalidRateLimit)
    _, True -> validate_runtime(config)
  }
}

fn valid_rate_limits(config: Config) -> Bool {
  case config.rate_limit_window_seconds > 0 {
    False -> False
    True -> {
      let largest_safe_capacity =
        9_223_372_036_854_775_807 / config.rate_limit_window_seconds
      [
        config.rate_limit_requests,
        config.rate_limit_subscriptions,
        config.rate_limit_topic_creations,
        config.rate_limit_auth_failures,
        config.rate_limit_attachment_mebibytes,
        config.rate_limit_attachment_uploads,
      ]
      |> list.all(fn(capacity) {
        capacity > 0 && capacity <= largest_safe_capacity
      })
    }
  }
}

fn validate_runtime(config: Config) -> Result(Config, Error) {
  case
    config.port,
    config.retention_seconds,
    config.cluster_enabled && config.database_backend != PostgreSQL,
    config.dev_open && !is_loopback(config.bind),
    config.attachment_file_size_bytes,
    config.attachment_total_size_bytes,
    config.attachment_retention_seconds,
    !is_loopback(config.bind) && option.is_none(config.base_url),
    config.postgres_port,
    config.cluster_enabled && string.is_empty(string.trim(config.node_id)),
    config.cluster_enabled && config.attachment_backend == Filesystem,
    config.attachment_backend == S3Compatible
    && list.any(
      [
        config.s3_endpoint,
        config.s3_bucket,
        config.s3_access_key,
        config.s3_secret_key,
      ],
      fn(value) { string.is_empty(string.trim(value)) },
    ),
    webpush_incomplete(config)
  {
    port, _, _, _, _, _, _, _, _, _, _, _, _ if port < 1 || port > 65_535 ->
      Error(InvalidPort(port))
    _, retention, _, _, _, _, _, _, _, _, _, _, _ if retention < 1 ->
      Error(InvalidRetention(retention))
    _, _, True, _, _, _, _, _, _, _, _, _, _ ->
      Error(ActiveActiveRequiresPostgres)
    _, _, _, True, _, _, _, _, _, _, _, _, _ -> Error(DevOpenRequiresLoopback)
    _, _, _, _, file, total, expiry, _, _, _, _, _, _
      if file < 1 || total < file || expiry < 1
    -> Error(InvalidAttachmentLimits)
    _, _, _, _, _, _, _, True, _, _, _, _, _ ->
      Error(PublicAttachmentsRequireBaseUrl)
    _, _, _, _, _, _, _, _, port, _, _, _, _ if port < 1 || port > 65_535 ->
      Error(InvalidPostgresPort(port))
    _, _, _, _, _, _, _, _, _, True, _, _, _ -> Error(MissingClusterNodeId)
    _, _, _, _, _, _, _, _, _, _, True, _, _ ->
      Error(ActiveActiveRequiresSharedAttachments)
    _, _, _, _, _, _, _, _, _, _, _, True, _ -> Error(MissingS3Configuration)
    _, _, _, _, _, _, _, _, _, _, _, _, True ->
      Error(InvalidWebPushConfiguration)
    _, _, _, _, _, _, _, _, _, _, _, _, _ -> validate_base_url(config)
  }
}

fn validate_base_url(config: Config) -> Result(Config, Error) {
  case config.base_url {
    Some(value) ->
      case valid_http_url(value) {
        True -> validate_relay(config)
        False -> Error(InvalidBaseUrl(value))
      }
    None -> validate_relay(config)
  }
}

fn validate_relay(config: Config) -> Result(Config, Error) {
  case string.is_empty(string.trim(config.relay_url)) {
    True -> validate_transport(config)
    False ->
      case
        config.base_url,
        string.starts_with(config.relay_url, "https://")
        || string.starts_with(config.relay_url, "http://")
      {
        Some(_), True -> validate_transport(config)
        _, _ -> Error(InvalidRelayConfiguration)
      }
  }
}

fn validate_transport(config: Config) -> Result(Config, Error) {
  let certificate_present =
    !string.is_empty(string.trim(config.tls_certificate))
  let key_present = !string.is_empty(string.trim(config.tls_key))
  case certificate_present != key_present {
    True -> Error(InvalidTlsConfiguration)
    False ->
      case
        list.find(config.trusted_proxies, fn(address) {
          !proxy.valid_address(address)
        })
      {
        Ok(address) -> Error(InvalidTrustedProxy(address))
        Error(_) -> Ok(config)
      }
  }
}

fn webpush_incomplete(config: Config) -> Bool {
  let fields = [
    config.webpush_public_key,
    config.webpush_private_key,
    config.webpush_subscriber,
  ]
  let present =
    fields
    |> list.filter(fn(value) { !string.is_empty(string.trim(value)) })
    |> list.length
  present > 0
  && {
    present < 3
    || !valid_vapid_keys(config.webpush_public_key, config.webpush_private_key)
    || !valid_webpush_subscriber(config.webpush_subscriber)
  }
}

fn valid_webpush_subscriber(value: String) -> Bool {
  let value = string.trim(value)
  string.starts_with(value, "https://")
  || string.starts_with(value, "mailto:")
  || string.contains(value, "@")
}

fn valid_http_url(value: String) -> Bool {
  case uri.parse(value) {
    Error(_) -> False
    Ok(parsed) ->
      case parsed.scheme, parsed.host, parsed.userinfo {
        Some("http"), Some(_), None | Some("https"), Some(_), None ->
          string.trim(value) == value
        _, _, _ -> False
      }
  }
}

fn is_loopback(bind: String) -> Bool {
  list.contains(["localhost", "127.0.0.1", "::1"], bind)
}

pub fn load(args: List(String)) -> Result(Config, Error) {
  use flag_values <- result.try(parse_flags(args))
  let toml_path =
    find_flag_value(args, "--config") |> option.unwrap("notify.toml")
  let toml_values = case read_file(toml_path) {
    Ok(contents) -> parse_toml(contents)
    Error(_) -> Ok(empty_partial())
  }
  use toml_values <- result.try(toml_values)
  use environment <- result.try(from_environment())
  resolve(defaults(), toml_values, environment, flag_values)
  |> validate
}

pub fn parse_toml(contents: String) -> Result(Partial, Error) {
  contents
  |> string.split("\n")
  |> parse_lines("", empty_partial())
}

fn parse_lines(
  lines: List(String),
  section: String,
  partial: Partial,
) -> Result(Partial, Error) {
  case lines {
    [] -> Ok(partial)
    [raw, ..rest] -> {
      let line = raw |> strip_comment |> string.trim
      case line {
        "" -> parse_lines(rest, section, partial)
        _ ->
          case string.starts_with(line, "[") && string.ends_with(line, "]") {
            True -> {
              let next_section =
                line
                |> string.drop_start(1)
                |> string.drop_end(1)
                |> string.trim
              parse_lines(rest, next_section, partial)
            }
            False ->
              case string.split_once(line, "=") {
                Error(_) -> Error(InvalidToml("expected key = value: " <> line))
                Ok(#(key, value)) -> {
                  use updated <- result.try(set_toml_value(
                    partial,
                    section <> "." <> string.trim(key),
                    string.trim(value),
                  ))
                  parse_lines(rest, section, updated)
                }
              }
          }
      }
    }
  }
}

fn strip_comment(line: String) -> String {
  strip_comment_loop(string.to_graphemes(line), False, False, [])
  |> list.reverse
  |> string.concat
}

fn strip_comment_loop(
  characters: List(String),
  quoted: Bool,
  escaped: Bool,
  retained: List(String),
) -> List(String) {
  case characters {
    [] -> retained
    ["#", ..] if !quoted -> retained
    ["\\", ..rest] if quoted && !escaped ->
      strip_comment_loop(rest, quoted, True, ["\\", ..retained])
    ["\"", ..rest] if !escaped ->
      strip_comment_loop(rest, !quoted, False, ["\"", ..retained])
    [character, ..rest] ->
      strip_comment_loop(rest, quoted, False, [character, ..retained])
  }
}

fn set_toml_value(
  partial: Partial,
  key: String,
  raw_value: String,
) -> Result(Partial, Error) {
  case key {
    ".bind" | "server.bind" ->
      Ok(Partial(..partial, bind: Some(unquote(raw_value))))
    ".port" | "server.port" -> {
      use value <- result.try(parse_int("port", raw_value))
      Ok(Partial(..partial, port: Some(value)))
    }
    ".base_url" | "server.base_url" ->
      Ok(Partial(..partial, base_url: Some(unquote(raw_value))))
    "server.max_request_bytes" -> {
      use value <- result.try(parse_int("server.max_request_bytes", raw_value))
      Ok(Partial(..partial, max_request_bytes: Some(value)))
    }
    ".database_path" | "storage.database_path" ->
      Ok(Partial(..partial, database_path: Some(unquote(raw_value))))
    "storage.backend" ->
      parse_database_backend(raw_value)
      |> result.map(fn(value) {
        Partial(..partial, database_backend: Some(value))
      })
    "postgres.host" ->
      Ok(Partial(..partial, postgres_host: Some(unquote(raw_value))))
    "postgres.port" -> {
      use value <- result.try(parse_int("postgres.port", raw_value))
      Ok(Partial(..partial, postgres_port: Some(value)))
    }
    "postgres.database" ->
      Ok(Partial(..partial, postgres_database: Some(unquote(raw_value))))
    "postgres.username" ->
      Ok(Partial(..partial, postgres_username: Some(unquote(raw_value))))
    "postgres.password" ->
      Ok(Partial(..partial, postgres_password: Some(unquote(raw_value))))
    "postgres.ssl" ->
      parse_postgres_ssl(raw_value)
      |> result.map(fn(value) { Partial(..partial, postgres_ssl: Some(value)) })
    ".retention_seconds" | "messages.retention_seconds" -> {
      use value <- result.try(parse_int("retention_seconds", raw_value))
      Ok(Partial(..partial, retention_seconds: Some(value)))
    }
    "rate_limit.requests" -> {
      use value <- result.try(parse_int("rate_limit.requests", raw_value))
      Ok(Partial(..partial, rate_limit_requests: Some(value)))
    }
    "rate_limit.subscriptions" -> {
      use value <- result.try(parse_int("rate_limit.subscriptions", raw_value))
      Ok(Partial(..partial, rate_limit_subscriptions: Some(value)))
    }
    "rate_limit.topic_creations" -> {
      use value <- result.try(parse_int("rate_limit.topic_creations", raw_value))
      Ok(Partial(..partial, rate_limit_topic_creations: Some(value)))
    }
    "rate_limit.auth_failures" -> {
      use value <- result.try(parse_int("rate_limit.auth_failures", raw_value))
      Ok(Partial(..partial, rate_limit_auth_failures: Some(value)))
    }
    "rate_limit.attachment_mebibytes" -> {
      use value <- result.try(parse_int(
        "rate_limit.attachment_mebibytes",
        raw_value,
      ))
      Ok(Partial(..partial, rate_limit_attachment_mebibytes: Some(value)))
    }
    "rate_limit.attachment_uploads" -> {
      use value <- result.try(parse_int(
        "rate_limit.attachment_uploads",
        raw_value,
      ))
      Ok(Partial(..partial, rate_limit_attachment_uploads: Some(value)))
    }
    "rate_limit.window_seconds" -> {
      use value <- result.try(parse_int("rate_limit.window_seconds", raw_value))
      Ok(Partial(..partial, rate_limit_window_seconds: Some(value)))
    }
    ".dev_open" | "server.dev_open" -> {
      use value <- result.try(parse_bool("dev_open", raw_value))
      Ok(Partial(..partial, dev_open: Some(value)))
    }
    "cluster.enabled" -> {
      use value <- result.try(parse_bool("cluster.enabled", raw_value))
      Ok(Partial(..partial, cluster_enabled: Some(value)))
    }
    "cluster.node_id" ->
      Ok(Partial(..partial, node_id: Some(unquote(raw_value))))
    "attachments.backend" ->
      parse_attachment_backend(raw_value)
      |> result.map(fn(value) {
        Partial(..partial, attachment_backend: Some(value))
      })
    "attachments.directory" ->
      Ok(Partial(..partial, attachment_directory: Some(unquote(raw_value))))
    "attachments.file_size_bytes" -> {
      use value <- result.try(parse_int(
        "attachments.file_size_bytes",
        raw_value,
      ))
      Ok(Partial(..partial, attachment_file_size_bytes: Some(value)))
    }
    "attachments.total_size_bytes" -> {
      use value <- result.try(parse_int(
        "attachments.total_size_bytes",
        raw_value,
      ))
      Ok(Partial(..partial, attachment_total_size_bytes: Some(value)))
    }
    "attachments.retention_seconds" -> {
      use value <- result.try(parse_int(
        "attachments.retention_seconds",
        raw_value,
      ))
      Ok(Partial(..partial, attachment_retention_seconds: Some(value)))
    }
    "s3.endpoint" ->
      Ok(Partial(..partial, s3_endpoint: Some(unquote(raw_value))))
    "s3.bucket" -> Ok(Partial(..partial, s3_bucket: Some(unquote(raw_value))))
    "s3.region" -> Ok(Partial(..partial, s3_region: Some(unquote(raw_value))))
    "s3.access_key" ->
      Ok(Partial(..partial, s3_access_key: Some(unquote(raw_value))))
    "s3.secret_key" ->
      Ok(Partial(..partial, s3_secret_key: Some(unquote(raw_value))))
    "s3.path_style" -> {
      use value <- result.try(parse_bool("s3.path_style", raw_value))
      Ok(Partial(..partial, s3_path_style: Some(value)))
    }
    "webpush.public_key" ->
      Ok(Partial(..partial, webpush_public_key: Some(unquote(raw_value))))
    "webpush.private_key" ->
      Ok(Partial(..partial, webpush_private_key: Some(unquote(raw_value))))
    "webpush.subscriber" ->
      Ok(Partial(..partial, webpush_subscriber: Some(unquote(raw_value))))
    "relay.url" | "relay.upstream_base_url" | ".upstream_base_url" ->
      Ok(Partial(..partial, relay_url: Some(unquote(raw_value))))
    "relay.token" | "relay.upstream_access_token" | ".upstream_access_token" ->
      Ok(Partial(..partial, relay_token: Some(unquote(raw_value))))
    "tls.certificate" | "tls.cert" ->
      Ok(Partial(..partial, tls_certificate: Some(unquote(raw_value))))
    "tls.key" -> Ok(Partial(..partial, tls_key: Some(unquote(raw_value))))
    "proxy.trusted" | "server.trusted_proxies" ->
      Ok(
        Partial(
          ..partial,
          trusted_proxies: Some(parse_address_list(unquote(raw_value))),
        ),
      )
    "logging.format" ->
      parse_log_format(raw_value)
      |> result.map(fn(value) { Partial(..partial, log_format: Some(value)) })
    _ -> Error(InvalidToml("unknown setting: " <> key))
  }
}

fn parse_address_list(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(address) { !string.is_empty(address) })
}

fn unquote(value: String) -> String {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    True -> value |> string.drop_start(1) |> string.drop_end(1)
    False -> value
  }
}

fn from_environment() -> Result(Partial, Error) {
  use port <- result.try(optional_env_int("NOTIFY_PORT"))
  use retention <- result.try(optional_env_int("NOTIFY_RETENTION_SECONDS"))
  use max_request_bytes <- result.try(optional_env_int(
    "NOTIFY_MAX_REQUEST_BYTES",
  ))
  use rate_limit_requests <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_REQUESTS",
  ))
  use rate_limit_subscriptions <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_SUBSCRIPTIONS",
  ))
  use rate_limit_topic_creations <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_TOPIC_CREATIONS",
  ))
  use rate_limit_auth_failures <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_AUTH_FAILURES",
  ))
  use rate_limit_attachment_mebibytes <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_ATTACHMENT_MEBIBYTES",
  ))
  use rate_limit_attachment_uploads <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_ATTACHMENT_UPLOADS",
  ))
  use rate_limit_window_seconds <- result.try(optional_env_int(
    "NOTIFY_RATE_LIMIT_WINDOW_SECONDS",
  ))
  use dev_open <- result.try(optional_env_bool("NOTIFY_DEV_OPEN"))
  use cluster_enabled <- result.try(optional_env_bool("NOTIFY_CLUSTER_ENABLED"))
  use postgres_port <- result.try(optional_env_int("NOTIFY_POSTGRES_PORT"))
  use database_backend <- result.try(
    getenv("NOTIFY_DATABASE_BACKEND")
    |> option.from_result
    |> option.map(parse_database_backend)
    |> transpose,
  )
  use postgres_ssl <- result.try(
    getenv("NOTIFY_POSTGRES_SSL")
    |> option.from_result
    |> option.map(parse_postgres_ssl)
    |> transpose,
  )
  use attachment_backend <- result.try(
    getenv("NOTIFY_ATTACHMENT_BACKEND")
    |> option.from_result
    |> option.map(parse_attachment_backend)
    |> transpose,
  )
  use log_format <- result.try(
    getenv("NOTIFY_LOG_FORMAT")
    |> option.from_result
    |> option.map(parse_log_format)
    |> transpose,
  )
  use s3_path_style <- result.try(optional_env_bool("NOTIFY_S3_PATH_STYLE"))
  use attachment_file_size <- result.try(optional_env_int(
    "NOTIFY_ATTACHMENT_FILE_SIZE_BYTES",
  ))
  use attachment_total_size <- result.try(optional_env_int(
    "NOTIFY_ATTACHMENT_TOTAL_SIZE_BYTES",
  ))
  use attachment_retention <- result.try(optional_env_int(
    "NOTIFY_ATTACHMENT_RETENTION_SECONDS",
  ))
  Ok(Partial(
    bind: getenv("NOTIFY_BIND") |> option.from_result,
    port:,
    base_url: getenv("NOTIFY_BASE_URL") |> option.from_result,
    database_backend:,
    database_path: getenv("NOTIFY_DATABASE_PATH") |> option.from_result,
    postgres_host: getenv("NOTIFY_POSTGRES_HOST") |> option.from_result,
    postgres_port:,
    postgres_database: getenv("NOTIFY_POSTGRES_DATABASE")
      |> option.from_result,
    postgres_username: getenv("NOTIFY_POSTGRES_USERNAME")
      |> option.from_result,
    postgres_password: getenv("NOTIFY_POSTGRES_PASSWORD")
      |> option.from_result,
    postgres_ssl:,
    node_id: getenv("NOTIFY_NODE_ID") |> option.from_result,
    retention_seconds: retention,
    max_request_bytes:,
    rate_limit_requests:,
    rate_limit_subscriptions:,
    rate_limit_topic_creations:,
    rate_limit_auth_failures:,
    rate_limit_attachment_mebibytes:,
    rate_limit_attachment_uploads:,
    rate_limit_window_seconds:,
    dev_open:,
    cluster_enabled:,
    attachment_backend:,
    attachment_directory: getenv("NOTIFY_ATTACHMENT_DIRECTORY")
      |> option.from_result,
    attachment_file_size_bytes: attachment_file_size,
    attachment_total_size_bytes: attachment_total_size,
    attachment_retention_seconds: attachment_retention,
    s3_endpoint: getenv("NOTIFY_S3_ENDPOINT") |> option.from_result,
    s3_bucket: getenv("NOTIFY_S3_BUCKET") |> option.from_result,
    s3_region: getenv("NOTIFY_S3_REGION") |> option.from_result,
    s3_access_key: getenv("NOTIFY_S3_ACCESS_KEY") |> option.from_result,
    s3_secret_key: getenv("NOTIFY_S3_SECRET_KEY") |> option.from_result,
    s3_path_style:,
    webpush_public_key: getenv("NOTIFY_WEBPUSH_PUBLIC_KEY")
      |> option.from_result,
    webpush_private_key: getenv("NOTIFY_WEBPUSH_PRIVATE_KEY")
      |> option.from_result,
    webpush_subscriber: getenv("NOTIFY_WEBPUSH_SUBSCRIBER")
      |> option.from_result,
    relay_url: environment_alias("NOTIFY_RELAY_URL", "NOTIFY_UPSTREAM_BASE_URL"),
    relay_token: environment_alias(
      "NOTIFY_RELAY_TOKEN",
      "NOTIFY_UPSTREAM_ACCESS_TOKEN",
    ),
    tls_certificate: getenv("NOTIFY_TLS_CERTIFICATE") |> option.from_result,
    tls_key: getenv("NOTIFY_TLS_KEY") |> option.from_result,
    trusted_proxies: getenv("NOTIFY_TRUSTED_PROXIES")
      |> option.from_result
      |> option.map(parse_address_list),
    log_format:,
  ))
}

fn environment_alias(primary: String, compatibility: String) -> Option(String) {
  getenv(primary)
  |> option.from_result
  |> option.or(getenv(compatibility) |> option.from_result)
}

fn optional_env_int(name: String) -> Result(Option(Int), Error) {
  case getenv(name) {
    Error(_) -> Ok(None)
    Ok(value) -> parse_int(name, value) |> result.map(Some)
  }
}

fn optional_env_bool(name: String) -> Result(Option(Bool), Error) {
  case getenv(name) {
    Error(_) -> Ok(None)
    Ok(value) -> parse_bool(name, value) |> result.map(Some)
  }
}

fn parse_flags(args: List(String)) -> Result(Partial, Error) {
  parse_flag_loop(args, empty_partial())
}

fn parse_flag_loop(
  args: List(String),
  partial: Partial,
) -> Result(Partial, Error) {
  case args {
    [] -> Ok(partial)
    ["--config", _, ..rest] -> parse_flag_loop(rest, partial)
    ["--listen-host", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, bind: Some(value)))
    ["--port", value, ..rest] -> {
      use port <- result.try(parse_int("--port", value))
      parse_flag_loop(rest, Partial(..partial, port: Some(port)))
    }
    ["--base-url", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, base_url: Some(value)))
    ["--database", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, database_path: Some(value)))
    ["--database-backend", value, ..rest] -> {
      use backend <- result.try(parse_database_backend(value))
      parse_flag_loop(rest, Partial(..partial, database_backend: Some(backend)))
    }
    ["--postgres-host", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, postgres_host: Some(value)))
    ["--postgres-port", value, ..rest] -> {
      use port <- result.try(parse_int("--postgres-port", value))
      parse_flag_loop(rest, Partial(..partial, postgres_port: Some(port)))
    }
    ["--postgres-database", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, postgres_database: Some(value)))
    ["--postgres-username", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, postgres_username: Some(value)))
    ["--postgres-password", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, postgres_password: Some(value)))
    ["--postgres-ssl", value, ..rest] -> {
      use ssl <- result.try(parse_postgres_ssl(value))
      parse_flag_loop(rest, Partial(..partial, postgres_ssl: Some(ssl)))
    }
    ["--node-id", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, node_id: Some(value)))
    ["--retention-seconds", value, ..rest] -> {
      use retention <- result.try(parse_int("--retention-seconds", value))
      parse_flag_loop(
        rest,
        Partial(..partial, retention_seconds: Some(retention)),
      )
    }
    ["--max-request-bytes", value, ..rest] -> {
      use size <- result.try(parse_int("--max-request-bytes", value))
      parse_flag_loop(rest, Partial(..partial, max_request_bytes: Some(size)))
    }
    ["--rate-limit-requests", value, ..rest] -> {
      use requests <- result.try(parse_int("--rate-limit-requests", value))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_requests: Some(requests)),
      )
    }
    ["--rate-limit-subscriptions", value, ..rest] -> {
      use capacity <- result.try(parse_int("--rate-limit-subscriptions", value))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_subscriptions: Some(capacity)),
      )
    }
    ["--rate-limit-topic-creations", value, ..rest] -> {
      use capacity <- result.try(parse_int(
        "--rate-limit-topic-creations",
        value,
      ))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_topic_creations: Some(capacity)),
      )
    }
    ["--rate-limit-auth-failures", value, ..rest] -> {
      use capacity <- result.try(parse_int("--rate-limit-auth-failures", value))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_auth_failures: Some(capacity)),
      )
    }
    ["--rate-limit-attachment-mebibytes", value, ..rest] -> {
      use capacity <- result.try(parse_int(
        "--rate-limit-attachment-mebibytes",
        value,
      ))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_attachment_mebibytes: Some(capacity)),
      )
    }
    ["--rate-limit-attachment-uploads", value, ..rest] -> {
      use capacity <- result.try(parse_int(
        "--rate-limit-attachment-uploads",
        value,
      ))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_attachment_uploads: Some(capacity)),
      )
    }
    ["--rate-limit-window", value, ..rest] -> {
      use window <- result.try(parse_int("--rate-limit-window", value))
      parse_flag_loop(
        rest,
        Partial(..partial, rate_limit_window_seconds: Some(window)),
      )
    }
    ["--dev-open", ..rest] ->
      parse_flag_loop(rest, Partial(..partial, dev_open: Some(True)))
    ["--cluster", ..rest] ->
      parse_flag_loop(rest, Partial(..partial, cluster_enabled: Some(True)))
    ["--attachment-backend", value, ..rest] -> {
      use backend <- result.try(parse_attachment_backend(value))
      parse_flag_loop(
        rest,
        Partial(..partial, attachment_backend: Some(backend)),
      )
    }
    ["--attachment-dir", value, ..rest] ->
      parse_flag_loop(
        rest,
        Partial(..partial, attachment_directory: Some(value)),
      )
    ["--attachment-file-size", value, ..rest] -> {
      use size <- result.try(parse_int("--attachment-file-size", value))
      parse_flag_loop(
        rest,
        Partial(..partial, attachment_file_size_bytes: Some(size)),
      )
    }
    ["--attachment-total-size", value, ..rest] -> {
      use size <- result.try(parse_int("--attachment-total-size", value))
      parse_flag_loop(
        rest,
        Partial(..partial, attachment_total_size_bytes: Some(size)),
      )
    }
    ["--attachment-retention-seconds", value, ..rest] -> {
      use expiry <- result.try(parse_int(
        "--attachment-retention-seconds",
        value,
      ))
      parse_flag_loop(
        rest,
        Partial(..partial, attachment_retention_seconds: Some(expiry)),
      )
    }
    ["--s3-endpoint", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, s3_endpoint: Some(value)))
    ["--s3-bucket", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, s3_bucket: Some(value)))
    ["--s3-region", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, s3_region: Some(value)))
    ["--s3-access-key", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, s3_access_key: Some(value)))
    ["--s3-secret-key", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, s3_secret_key: Some(value)))
    ["--s3-path-style", value, ..rest] -> {
      use path_style <- result.try(parse_bool("--s3-path-style", value))
      parse_flag_loop(rest, Partial(..partial, s3_path_style: Some(path_style)))
    }
    ["--webpush-public-key", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, webpush_public_key: Some(value)))
    ["--webpush-private-key", value, ..rest] ->
      parse_flag_loop(
        rest,
        Partial(..partial, webpush_private_key: Some(value)),
      )
    ["--webpush-subscriber", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, webpush_subscriber: Some(value)))
    ["--relay-url", value, ..rest] | ["--upstream-base-url", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, relay_url: Some(value)))
    ["--relay-token", value, ..rest]
    | ["--upstream-access-token", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, relay_token: Some(value)))
    ["--tls-certificate", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, tls_certificate: Some(value)))
    ["--tls-key", value, ..rest] ->
      parse_flag_loop(rest, Partial(..partial, tls_key: Some(value)))
    ["--trusted-proxies", value, ..rest] ->
      parse_flag_loop(
        rest,
        Partial(..partial, trusted_proxies: Some(parse_address_list(value))),
      )
    ["--log-format", value, ..rest] -> {
      use format <- result.try(parse_log_format(value))
      parse_flag_loop(rest, Partial(..partial, log_format: Some(format)))
    }
    [flag, ..rest] ->
      case string.starts_with(flag, "--") {
        True -> Error(InvalidFlag(flag))
        False -> parse_flag_loop(rest, partial)
      }
  }
}

fn find_flag_value(args: List(String), target: String) -> Option(String) {
  case args {
    [] -> None
    [flag, value, ..] if flag == target -> Some(value)
    [_, ..rest] -> find_flag_value(rest, target)
  }
}

fn parse_int(name: String, value: String) -> Result(Int, Error) {
  int.parse(value) |> result.map_error(fn(_) { InvalidInteger(name, value) })
}

fn parse_bool(name: String, raw: String) -> Result(Bool, Error) {
  case string.lowercase(unquote(raw)) {
    "true" | "1" | "yes" | "on" -> Ok(True)
    "false" | "0" | "no" | "off" -> Ok(False)
    value -> Error(InvalidBoolean(name, value))
  }
}

fn parse_database_backend(raw: String) -> Result(DatabaseBackend, Error) {
  case raw |> unquote |> string.lowercase {
    "sqlite" -> Ok(SQLite)
    "postgres" | "postgresql" -> Ok(PostgreSQL)
    value ->
      Error(InvalidToml(
        "storage.backend must be sqlite or postgres, got " <> value,
      ))
  }
}

fn parse_postgres_ssl(raw: String) -> Result(PostgresSsl, Error) {
  case raw |> unquote |> string.lowercase {
    "disabled" | "disable" | "off" -> Ok(SslDisabled)
    "verified" | "verify-full" | "required" -> Ok(SslVerified)
    "unverified" | "require" -> Ok(SslUnverified)
    value ->
      Error(InvalidToml(
        "postgres.ssl must be disabled, verified, or unverified, got " <> value,
      ))
  }
}

fn parse_attachment_backend(raw: String) -> Result(AttachmentBackend, Error) {
  case raw |> unquote |> string.lowercase {
    "filesystem" | "local" -> Ok(Filesystem)
    "shared-filesystem" | "shared_filesystem" | "shared" -> Ok(SharedFilesystem)
    "postgres" | "postgresql" | "postgres-blob" -> Ok(PostgreSQLBlob)
    "s3" | "s3-compatible" -> Ok(S3Compatible)
    value ->
      Error(InvalidToml(
        "attachments.backend must be filesystem, shared-filesystem, postgres, or s3, got "
        <> value,
      ))
  }
}

fn parse_log_format(raw: String) -> Result(LogFormat, Error) {
  case raw |> unquote |> string.lowercase {
    "human" | "text" -> Ok(HumanLogs)
    "json" -> Ok(JsonLogs)
    value ->
      Error(InvalidToml("logging.format must be human or json, got " <> value))
  }
}

fn transpose(value: Option(Result(a, e))) -> Result(Option(a), e) {
  case value {
    None -> Ok(None)
    Some(Ok(value)) -> Ok(Some(value))
    Some(Error(error)) -> Error(error)
  }
}

pub fn to_toml(config: Config) -> String {
  "[server]\n"
  <> "bind = \""
  <> config.bind
  <> "\"\nport = "
  <> int.to_string(config.port)
  <> option_string("\nbase_url = \"", config.base_url, "\"")
  <> "\ndev_open = "
  <> bool_string(config.dev_open)
  <> "\nmax_request_bytes = "
  <> int.to_string(config.max_request_bytes)
  <> "\n\n[storage]\ndatabase_path = \""
  <> config.database_path
  <> "\"\nbackend = \""
  <> database_backend_string(config.database_backend)
  <> "\"\n\n[postgres]\nhost = \""
  <> config.postgres_host
  <> "\"\nport = "
  <> int.to_string(config.postgres_port)
  <> "\ndatabase = \""
  <> config.postgres_database
  <> "\"\nusername = \""
  <> config.postgres_username
  <> "\"\nssl = \""
  <> postgres_ssl_string(config.postgres_ssl)
  <> "\"\n# password is accepted via NOTIFY_POSTGRES_PASSWORD and is never displayed\n\n[messages]\nretention_seconds = "
  <> int.to_string(config.retention_seconds)
  <> "\n\n[rate_limit]\nrequests = "
  <> int.to_string(config.rate_limit_requests)
  <> "\nsubscriptions = "
  <> int.to_string(config.rate_limit_subscriptions)
  <> "\ntopic_creations = "
  <> int.to_string(config.rate_limit_topic_creations)
  <> "\nauth_failures = "
  <> int.to_string(config.rate_limit_auth_failures)
  <> "\nattachment_mebibytes = "
  <> int.to_string(config.rate_limit_attachment_mebibytes)
  <> "\nattachment_uploads = "
  <> int.to_string(config.rate_limit_attachment_uploads)
  <> "\nwindow_seconds = "
  <> int.to_string(config.rate_limit_window_seconds)
  <> "\n\n[cluster]\nenabled = "
  <> bool_string(config.cluster_enabled)
  <> "\nnode_id = \""
  <> config.node_id
  <> "\""
  <> "\n\n[attachments]\nbackend = \""
  <> attachment_backend_string(config.attachment_backend)
  <> "\"\ndirectory = \""
  <> config.attachment_directory
  <> "\"\nfile_size_bytes = "
  <> int.to_string(config.attachment_file_size_bytes)
  <> "\ntotal_size_bytes = "
  <> int.to_string(config.attachment_total_size_bytes)
  <> "\nretention_seconds = "
  <> int.to_string(config.attachment_retention_seconds)
  <> "\n\n[s3]\nendpoint = \""
  <> config.s3_endpoint
  <> "\"\nbucket = \""
  <> config.s3_bucket
  <> "\"\nregion = \""
  <> config.s3_region
  <> "\"\npath_style = "
  <> bool_string(config.s3_path_style)
  <> "\n# credentials are accepted via NOTIFY_S3_ACCESS_KEY and NOTIFY_S3_SECRET_KEY and are never displayed"
  <> "\n\n[webpush]\npublic_key = \""
  <> config.webpush_public_key
  <> "\"\nsubscriber = \""
  <> config.webpush_subscriber
  <> "\"\n# private_key is accepted via NOTIFY_WEBPUSH_PRIVATE_KEY and is never displayed"
  <> "\n\n[relay]\nurl = \""
  <> config.relay_url
  <> "\"\n# token is accepted via NOTIFY_RELAY_TOKEN and is never displayed"
  <> "\n\n[tls]\ncertificate = \""
  <> config.tls_certificate
  <> "\"\nkey = \""
  <> config.tls_key
  <> "\"\n\n[proxy]\ntrusted = \""
  <> string.join(config.trusted_proxies, ", ")
  <> "\""
  <> "\n\n[logging]\nformat = \""
  <> log_format_string(config.log_format)
  <> "\""
  <> "\n"
}

fn database_backend_string(value: DatabaseBackend) -> String {
  case value {
    SQLite -> "sqlite"
    PostgreSQL -> "postgres"
  }
}

fn postgres_ssl_string(value: PostgresSsl) -> String {
  case value {
    SslDisabled -> "disabled"
    SslVerified -> "verified"
    SslUnverified -> "unverified"
  }
}

fn attachment_backend_string(value: AttachmentBackend) -> String {
  case value {
    Filesystem -> "filesystem"
    SharedFilesystem -> "shared-filesystem"
    PostgreSQLBlob -> "postgres"
    S3Compatible -> "s3"
  }
}

fn log_format_string(value: LogFormat) -> String {
  case value {
    HumanLogs -> "human"
    JsonLogs -> "json"
  }
}

fn option_string(
  prefix: String,
  value: Option(String),
  suffix: String,
) -> String {
  case value {
    None -> ""
    Some(value) -> prefix <> value <> suffix
  }
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    InvalidPort(port) ->
      "port " <> int.to_string(port) <> " is invalid; choose 1-65535"
    InvalidRetention(value) ->
      "retention_seconds " <> int.to_string(value) <> " must be positive"
    InvalidRequestSize(value) ->
      "server.max_request_bytes " <> int.to_string(value) <> " must be positive"
    InvalidRateLimit ->
      "all rate_limit capacities and rate_limit.window_seconds must be positive and fit PostgreSQL BIGINT"
    DevOpenRequiresLoopback ->
      "--dev-open is only allowed with localhost, 127.0.0.1, or ::1"
    ActiveActiveRequiresPostgres ->
      "active-active requires PostgreSQL; SQLite is single-node only"
    InvalidAttachmentLimits ->
      "attachment limits must be positive and total_size_bytes must be at least file_size_bytes"
    PublicAttachmentsRequireBaseUrl ->
      "server.base_url is required when binding outside localhost so attachment URLs are reachable"
    InvalidBaseUrl(value) ->
      "server.base_url must be an absolute http(s) URL without embedded credentials, got "
      <> value
    InvalidPostgresPort(port) ->
      "PostgreSQL port " <> int.to_string(port) <> " is invalid; choose 1-65535"
    MissingClusterNodeId -> "cluster.node_id must not be empty"
    ActiveActiveRequiresSharedAttachments ->
      "active-active requires shared attachment storage; use shared-filesystem, postgres, or s3"
    MissingS3Configuration ->
      "S3 attachments require endpoint, bucket, access key, and secret key"
    InvalidWebPushConfiguration ->
      "Web Push requires public_key, private_key, and subscriber together; generate keys with `notify webpush keys`"
    InvalidRelayConfiguration ->
      "mobile relay requires an http(s) relay.url and an explicit server.base_url"
    InvalidTlsConfiguration ->
      "TLS requires both tls.certificate and tls.key; configure both paths or neither"
    InvalidTrustedProxy(address) ->
      "proxy.trusted contains an invalid IP address: " <> address
    InvalidInteger(name, value) -> name <> " must be an integer, got " <> value
    InvalidBoolean(name, value) ->
      name <> " must be true or false, got " <> value
    InvalidToml(detail) -> "invalid notify.toml: " <> detail
    InvalidFlag(flag) -> "unknown configuration flag: " <> flag
  }
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "valid_vapid_keys")
fn valid_vapid_keys(public_key: String, private_key: String) -> Bool
