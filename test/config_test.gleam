import gleam/option.{None, Some}
import gleam/string
import notify/config

pub fn precedence_is_flags_then_environment_then_toml_then_defaults_test() {
  let defaults = config.defaults()
  let toml =
    config.Partial(
      ..config.empty_partial(),
      bind: Some("toml.example"),
      port: Some(7000),
      database_path: Some("toml.db"),
      base_url: Some("https://toml.example"),
    )
  let environment =
    config.Partial(
      ..config.empty_partial(),
      bind: Some("env.example"),
      port: Some(8000),
    )
  let flags = config.Partial(..config.empty_partial(), port: Some(9000))

  let value = config.resolve(defaults, toml, environment, flags)
  assert value.bind == "env.example"
  assert value.port == 9000
  assert value.database_path == "toml.db"
  assert value.base_url == Some("https://toml.example")
  assert value.retention_seconds == 43_200
}

pub fn rejects_unsafe_or_impossible_combinations_test() {
  let cluster = config.Config(..config.defaults(), cluster_enabled: True)
  let assert Error(config.ActiveActiveRequiresPostgres) =
    config.validate(cluster)

  let dev_open =
    config.Config(..config.defaults(), bind: "0.0.0.0", dev_open: True)
  let assert Error(config.DevOpenRequiresLoopback) = config.validate(dev_open)

  let bad_port = config.Config(..config.defaults(), port: 70_000)
  let assert Error(config.InvalidPort(70_000)) = config.validate(bad_port)

  let public_without_url =
    config.Config(..config.defaults(), bind: "0.0.0.0", base_url: None)
  let assert Error(config.PublicAttachmentsRequireBaseUrl) =
    config.validate(public_without_url)

  let malformed_base_url =
    config.Config(
      ..config.defaults(),
      base_url: Some("ftp://user@example.test"),
    )
  let assert Error(config.InvalidBaseUrl("ftp://user@example.test")) =
    config.validate(malformed_base_url)

  let credentialed_base_url =
    config.Config(
      ..config.defaults(),
      base_url: Some("https://admin:secret@example.test"),
    )
  let assert Error(config.InvalidBaseUrl(_)) =
    config.validate(credentialed_base_url)
}

pub fn attachment_configuration_parses_from_toml_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[server]\nbase_url = \"https://notify.example\"\n[attachments]\nbackend = \"shared-filesystem\"\ndirectory = \"shared/attachments\"\nfile_size_bytes = 2048\ntotal_size_bytes = 8192\nretention_seconds = 7200\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert resolved.base_url == Some("https://notify.example")
  assert resolved.attachment_backend == config.SharedFilesystem
  assert resolved.attachment_directory == "shared/attachments"
  assert resolved.attachment_file_size_bytes == 2048
  assert resolved.attachment_total_size_bytes == 8192
  assert resolved.attachment_retention_seconds == 7200
}

pub fn cluster_rejects_node_local_attachment_storage_test() {
  let value =
    config.Config(
      ..config.defaults(),
      database_backend: config.PostgreSQL,
      cluster_enabled: True,
      attachment_backend: config.Filesystem,
    )
  let assert Error(config.ActiveActiveRequiresSharedAttachments) =
    config.validate(value)
}

pub fn s3_configuration_is_typed_and_secrets_are_redacted_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[attachments]\nbackend = \"s3\"\n[s3]\nendpoint = \"https://objects.example\"\nbucket = \"notify\"\nregion = \"ap-northeast-1\"\naccess_key = \"access-secret\"\nsecret_key = \"very-secret\"\npath_style = true\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert resolved.attachment_backend == config.S3Compatible
  assert resolved.s3_path_style
  assert config.validate(resolved) == Ok(resolved)
  let shown = config.to_toml(resolved)
  assert !string.contains(shown, "access-secret")
  assert !string.contains(shown, "very-secret")
  assert string.contains(shown, "NOTIFY_S3_ACCESS_KEY")
  assert string.contains(shown, "NOTIFY_S3_SECRET_KEY")
}

pub fn webpush_configuration_requires_a_complete_keypair_and_redacts_private_key_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[webpush]\npublic_key = \"BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8\"\nprivate_key = \"yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw\"\nsubscriber = \"admin@example.test\"\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert config.validate(resolved) == Ok(resolved)
  assert string.starts_with(resolved.webpush_public_key, "BP4z9")
  let shown = config.to_toml(resolved)
  assert !string.contains(shown, "yfWPiYE")
  assert string.contains(shown, "NOTIFY_WEBPUSH_PRIVATE_KEY")

  let incomplete =
    config.Config(..config.defaults(), webpush_public_key: "public-only")
  assert config.validate(incomplete)
    == Error(config.InvalidWebPushConfiguration)
}

pub fn mobile_relay_requires_canonical_base_url_and_redacts_token_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[server]\nbase_url = \"https://notify.example\"\n[relay]\nurl = \"https://ntfy.example\"\ntoken = \"tk_private_relay_token\"\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert config.validate(resolved) == Ok(resolved)
  assert resolved.relay_url == "https://ntfy.example"
  let shown = config.to_toml(resolved)
  assert !string.contains(shown, "tk_private_relay_token")
  assert string.contains(shown, "NOTIFY_RELAY_TOKEN")

  let missing_base =
    config.Config(..config.defaults(), relay_url: "https://ntfy.example")
  assert config.validate(missing_base)
    == Error(config.InvalidRelayConfiguration)
}

pub fn mobile_relay_accepts_ntfy_upstream_compatibility_names_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[server]\nbase_url = \"https://notify.example/#public\"\n[relay]\nupstream_base_url = \"https://ntfy.example\"\nupstream_access_token = \"tk_upstream_secret\"\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert resolved.base_url == Some("https://notify.example/#public")
  assert resolved.relay_url == "https://ntfy.example"
  assert resolved.relay_token == "tk_upstream_secret"
  assert config.validate(resolved) == Ok(resolved)
}

pub fn postgres_cluster_configuration_is_typed_and_secrets_are_redacted_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[storage]\nbackend = \"postgres\"\n[postgres]\nhost = \"db\"\nport = 5433\ndatabase = \"notify_prod\"\nusername = \"notify\"\npassword = \"top-secret\"\nssl = \"verified\"\n[cluster]\nenabled = true\nnode_id = \"node-a\"\n[attachments]\nbackend = \"postgres\"\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert config.validate(resolved) == Ok(resolved)
  assert resolved.database_backend == config.PostgreSQL
  assert resolved.postgres_ssl == config.SslVerified
  let shown = config.to_toml(resolved)
  assert !string.contains(shown, "top-secret")
  assert string.contains(shown, "NOTIFY_POSTGRES_PASSWORD")
}

pub fn tls_and_trusted_proxy_configuration_is_typed_test() {
  let assert Ok(partial) =
    config.parse_toml(
      "[tls]\ncertificate = \"certs/server.pem\"\nkey = \"certs/server-key.pem\"\n[proxy]\ntrusted = \"127.0.0.1, 10.0.0.10\"\n",
    )
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert resolved.tls_certificate == "certs/server.pem"
  assert resolved.tls_key == "certs/server-key.pem"
  assert resolved.trusted_proxies == ["127.0.0.1", "10.0.0.10"]
  assert config.validate(resolved) == Ok(resolved)

  let incomplete =
    config.Config(..config.defaults(), tls_certificate: "certs/server.pem")
  assert config.validate(incomplete) == Error(config.InvalidTlsConfiguration)
}

pub fn request_limits_follow_toml_environment_flag_precedence_test() {
  let assert Ok(toml) =
    config.parse_toml(
      "[server]\nmax_request_bytes = 4096\n[rate_limit]\nrequests = 40\nsubscriptions = 12\ntopic_creations = 20\nauth_failures = 5\nattachment_mebibytes = 80\nattachment_uploads = 8\nwindow_seconds = 30\n",
    )
  let environment =
    config.Partial(..config.empty_partial(), rate_limit_requests: Some(50))
  let flags =
    config.Partial(..config.empty_partial(), rate_limit_requests: Some(60))
  let resolved = config.resolve(config.defaults(), toml, environment, flags)
  assert resolved.max_request_bytes == 4096
  assert resolved.rate_limit_requests == 60
  assert resolved.rate_limit_subscriptions == 12
  assert resolved.rate_limit_topic_creations == 20
  assert resolved.rate_limit_auth_failures == 5
  assert resolved.rate_limit_attachment_mebibytes == 80
  assert resolved.rate_limit_attachment_uploads == 8
  assert resolved.rate_limit_window_seconds == 30

  let shown = config.to_toml(resolved)
  assert string.contains(shown, "subscriptions = 12")
  assert string.contains(shown, "attachment_mebibytes = 80")

  let invalid = config.Config(..resolved, rate_limit_auth_failures: 0)
  assert config.validate(invalid) == Error(config.InvalidRateLimit)
}

pub fn logging_format_is_typed_and_configurable_test() {
  let assert Ok(partial) = config.parse_toml("[logging]\nformat = \"json\"\n")
  let resolved =
    config.resolve(
      config.defaults(),
      partial,
      config.empty_partial(),
      config.empty_partial(),
    )
  assert resolved.log_format == config.JsonLogs
  assert string.contains(config.to_toml(resolved), "format = \"json\"")
}
