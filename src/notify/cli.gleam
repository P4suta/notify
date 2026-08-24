import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/access
import notify/attachment_migration
import notify/attachment_store
import notify/attachment_store/filesystem as attachment_filesystem
import notify/backup
import notify/config
import notify/core/acl
import notify/doctor as notify_doctor
import notify/identity
import notify/identity/postgres as identity_postgres
import notify/identity/sqlite as identity_sqlite
import notify/migration/ntfy as ntfy_migration
import notify/runtime
import notify/security/token
import notify/server
import notify/storage.{type Storage}
import notify/storage/postgres as storage_postgres
import notify/storage/sqlite

pub fn setup(args: List(String)) -> Nil {
  use configuration <- with_config(args)
  let runtime.Clock(now) = runtime.system_clock()
  case start_identity(configuration, now) {
    Error(error) -> identity_failure(error)
    Ok(#(store, None)) ->
      case store.setup_required() {
        Ok(False) -> io.println("setup is already complete")
        Ok(True) ->
          fail(
            "an unexpired setup challenge is already active; use the URL printed by the node that issued it or retry after 15 minutes",
          )
        Error(error) -> identity_failure(error)
      }
    Ok(#(store, Some(setup_token))) -> {
      let username = flag_value(args, "--username") |> option.unwrap("admin")
      let anonymous =
        flag_value(args, "--anonymous-access")
        |> option.map(parse_permission)
        |> option.unwrap(Ok(acl.Deny))
      case password_value(args), anonymous, access.managed(store) {
        Error(_), _, _ -> fail("unable to read password")
        _, Error(_), _ ->
          fail(
            "invalid --anonymous-access; use deny, read, write, or read-write",
          )
        _, _, Error(_) -> fail("Argon2id password subsystem is unavailable")
        Ok(password), Ok(permission), Ok(control) -> {
          let runtime.IdGenerator(next_id) = runtime.secure_ids()
          case
            access.complete_setup(
              control,
              setup_token,
              "u_" <> next_id(),
              username,
              password,
              permission,
              now(),
            )
          {
            Ok(_) ->
              io.println(
                "setup complete; administrator " <> username <> " created",
              )
            Error(error) -> access_failure(error)
          }
        }
      }
    }
  }
}

pub fn user(action: String, args: List(String)) -> Nil {
  use control <- with_access(args)
  case action, positional(args) {
    "add", [username, ..] -> {
      let role = case has_flag(args, "--admin") {
        True -> acl.Admin
        False -> acl.User
      }
      let runtime.Clock(now) = runtime.system_clock()
      let runtime.IdGenerator(next_id) = runtime.secure_ids()
      case password_value(args) {
        Error(_) -> fail("unable to read password")
        Ok(password) ->
          case
            access.add_user(
              control,
              "u_" <> next_id(),
              username,
              password,
              role,
              now(),
            )
          {
            Ok(created) ->
              io.println(created.username <> "\t" <> role_string(created.role))
            Error(error) -> access_failure(error)
          }
      }
    }
    "list", _ ->
      case access.list_users(control) {
        Error(error) -> access_failure(error)
        Ok(users) ->
          list.each(users, fn(item) {
            io.println(
              item.username
              <> "\t"
              <> role_string(item.role)
              <> "\t"
              <> int.to_string(item.created_at),
            )
          })
      }
    "delete", [username, ..] ->
      case access.delete_user(control, username) {
        Ok(_) -> io.println("deleted user " <> username)
        Error(error) -> access_failure(error)
      }
    "password", [username, ..] ->
      case password_value(args) {
        Error(_) -> fail("unable to read password")
        Ok(password) ->
          case access.change_password(control, username, password) {
            Ok(_) -> io.println("password updated for " <> username)
            Error(error) -> access_failure(error)
          }
      }
    _, _ -> fail("usage: notify user add|list|delete|password [username]")
  }
}

pub fn token_command(action: String, args: List(String)) -> Nil {
  use control <- with_access(args)
  case action, positional(args) {
    "create", [username, ..] -> {
      let label = flag_value(args, "--label") |> option.unwrap("")
      let expires =
        flag_value(args, "--expires") |> option.map(int.parse) |> transpose
      case expires {
        Error(_) -> fail("--expires must be a Unix timestamp")
        Ok(expires) -> {
          let runtime.Clock(now) = runtime.system_clock()
          let runtime.IdGenerator(next_id) = runtime.secure_ids()
          case
            access.create_token_for_username(
              control,
              fn() { "tok_" <> next_id() },
              username,
              label,
              expires,
              now(),
              token.secure_entropy,
            )
          {
            Error(error) -> access_failure(error)
            Ok(#(stored, raw)) -> {
              io.println("token created: " <> stored.id)
              io.println("copy now; it will not be shown again:")
              io.println(raw)
            }
          }
        }
      }
    }
    "list", [username, ..] ->
      case access.list_tokens(control, username) {
        Error(error) -> access_failure(error)
        Ok(tokens) ->
          list.each(tokens, fn(item) {
            io.println(
              item.id
              <> "\t"
              <> item.prefix
              <> "\t"
              <> item.label
              <> "\t"
              <> expiry_string(item.expires),
            )
          })
      }
    "revoke", [id, ..] ->
      case access.revoke_token(control, id) {
        Ok(_) -> io.println("revoked token " <> id)
        Error(error) -> access_failure(error)
      }
    _, _ -> fail("usage: notify token create|list|revoke <username-or-id>")
  }
}

pub fn access_command(action: String, args: List(String)) -> Nil {
  use control <- with_access(args)
  case action, positional(args) {
    "grant", [username, pattern, permission, ..] ->
      case parse_permission(permission) {
        Error(_) -> fail("permission must be deny, read, write, or read-write")
        Ok(permission) ->
          case access.grant(control, username, pattern, permission) {
            Ok(rule) -> print_rule(rule)
            Error(error) -> access_failure(error)
          }
      }
    "revoke", [username, pattern, ..] ->
      case access.revoke_grant(control, username, pattern) {
        Ok(_) -> io.println("revoked " <> username <> " " <> pattern)
        Error(error) -> access_failure(error)
      }
    "list", names -> {
      let username = case names {
        [name, ..] -> Some(name)
        [] -> None
      }
      case access.list_grants(control, username) {
        Error(error) -> access_failure(error)
        Ok(rules) -> list.each(rules, print_rule)
      }
    }
    _, _ ->
      fail(
        "usage: notify access grant|revoke|list [username] [pattern] [permission]",
      )
  }
}

pub fn publish(args: List(String)) -> Nil {
  case positional(args) {
    [topic, message, ..] -> {
      use configuration <- with_config(args)
      let url = server_url(args, configuration) <> "/" <> topic
      let headers = authorization_headers(args)
      case http_request("POST", url, headers, bit_array.from_string(message)) {
        Error(detail) -> fail("publish failed: " <> detail)
        Ok(#(status, body)) if status >= 200 && status < 300 -> print_bytes(body)
        Ok(#(status, body)) -> {
          print_bytes(body)
          fail("publish returned HTTP " <> int.to_string(status))
        }
      }
    }
    _ ->
      fail(
        "usage: notify publish <topic> <message> [--server URL] [--token TOKEN]",
      )
  }
}

pub fn subscribe(args: List(String)) -> Nil {
  case positional(args) {
    [topics, ..] -> {
      use configuration <- with_config(args)
      let since = flag_value(args, "--since") |> option.unwrap("all")
      let url =
        server_url(args, configuration)
        <> "/"
        <> topics
        <> "/json?poll=1&since="
        <> since
      case http_request("GET", url, authorization_headers(args), <<>>) {
        Error(detail) -> fail("subscribe failed: " <> detail)
        Ok(#(status, body)) if status >= 200 && status < 300 -> print_bytes(body)
        Ok(#(status, body)) -> {
          print_bytes(body)
          fail("subscribe returned HTTP " <> int.to_string(status))
        }
      }
    }
    _ ->
      fail(
        "usage: notify subscribe <topic[,topic]> [--server URL] [--token TOKEN]",
      )
  }
}

pub fn db(action: String, args: List(String)) -> Nil {
  use configuration <- with_config(args)
  case action, configuration.database_backend {
    "backup", config.SQLite ->
      case positional(args) {
        [destination, ..] ->
          case backup.create_sqlite(configuration.database_path, destination) {
            Ok(_) -> io.println("SQLite backup verified: " <> destination)
            Error(error) -> fail(backup.error_message(error))
          }
        _ -> fail("usage: notify db backup <snapshot-path>")
      }
    "verify", config.SQLite ->
      case positional(args) {
        [snapshot, ..] ->
          case backup.verify_sqlite(snapshot) {
            Ok(_) -> io.println("SQLite backup is valid: " <> snapshot)
            Error(error) -> fail(backup.error_message(error))
          }
        _ -> fail("usage: notify db verify <snapshot-path>")
      }
    "restore", config.SQLite ->
      case positional(args), flag_value(args, "--to") {
        [snapshot, ..], Some(destination) ->
          case backup.restore_sqlite(snapshot, destination) {
            Ok(_) ->
              io.println("SQLite backup restored and verified: " <> destination)
            Error(error) -> fail(backup.error_message(error))
          }
        _, _ ->
          fail("usage: notify db restore <snapshot-path> --to <new-db-path>")
      }
    "backup", config.PostgreSQL
    | "verify", config.PostgreSQL
    | "restore", config.PostgreSQL
    ->
      fail(
        "PostgreSQL backup and restore must use pg_dump/pg_restore with your database operator's retention policy",
      )
    "migrate", _ ->
      case open_message_storage(configuration), open_identity(configuration) {
        Ok(_), Ok(_) -> io.println("database migrations applied")
        _, _ -> fail("database migration failed")
      }
    "status", _ ->
      case open_message_storage(configuration), open_identity(configuration) {
        Ok(messages), Ok(identity) ->
          case messages.health(), identity.setup_required() {
            Ok(_), Ok(required) ->
              io.println(
                "database healthy; schema current; setup_required="
                <> bool_string(required),
              )
            _, _ -> fail("database health check failed")
          }
        _, _ -> fail("database unavailable")
      }
    _, _ -> fail("usage: notify db migrate|status|backup|verify|restore")
  }
}

pub fn webpush_keys() -> Nil {
  case generate_vapid_keys() {
    Error(detail) -> fail("VAPID key generation failed: " <> detail)
    Ok(#(public, private)) -> {
      io.println("[webpush]")
      io.println("public_key = \"" <> public <> "\"")
      io.println("private_key = \"" <> private <> "\"")
    }
  }
}

pub fn attachments(action: String, args: List(String)) -> Nil {
  case action {
    "migrate" -> {
      use configuration <- with_config(args)
      case
        flag_value(args, "--from-dir")
        |> option.or(flag_value(args, "--source-dir"))
      {
        None ->
          fail("usage: notify attachments migrate --from-dir PATH [--dry-run]")
        Some(source_directory) ->
          case
            attachment_filesystem.start(
              source_directory,
              max_file_bytes: configuration.attachment_file_size_bytes,
              max_total_bytes: configuration.attachment_total_size_bytes,
            ),
            server.open_attachment_store(configuration)
          {
            Error(error), _ | _, Error(error) ->
              fail("attachment store unavailable: " <> attachment_error(error))
            Ok(source), Ok(destination) ->
              case
                attachment_migration.run(
                  source,
                  destination,
                  dry_run: has_flag(args, "--dry-run"),
                )
              {
                Error(error) ->
                  fail(
                    "attachment migration failed: "
                    <> attachment_migration_error(error),
                  )
                Ok(report) ->
                  io.println(
                    case report.dry_run {
                      True -> "dry-run complete"
                      False -> "attachment migration complete"
                    }
                    <> "; scanned="
                    <> int.to_string(report.scanned)
                    <> "; migrated="
                    <> int.to_string(report.migrated)
                    <> "; skipped="
                    <> int.to_string(report.skipped)
                    <> "; bytes="
                    <> int.to_string(report.bytes),
                  )
              }
          }
      }
    }
    _ -> fail("usage: notify attachments migrate --from-dir PATH [--dry-run]")
  }
}

pub fn doctor(args: List(String)) -> Nil {
  use configuration <- with_config(args)
  let checks = notify_doctor.run(configuration)
  list.each(checks, fn(check) { io.println(notify_doctor.render(check)) })
  case notify_doctor.has_failures(checks) {
    True -> fail("doctor found one or more failures")
    False -> io.println("PASS doctor: all required dependencies are healthy")
  }
}

pub fn migrate_ntfy(args: List(String)) -> Nil {
  use configuration <- with_config(args)
  use source_config <- with_ntfy_source_config(args)
  case configuration.database_backend {
    config.PostgreSQL ->
      fail(
        "ntfy migration currently targets an offline SQLite database; migrate locally, then use PostgreSQL migration tooling",
      )
    config.SQLite -> {
      let cache =
        prefer_option(
          flag_value(args, "--cache-file"),
          source_config.cache_file,
        )
      let auth =
        prefer_option(flag_value(args, "--auth-file"), source_config.auth_file)
      let webpush =
        prefer_option(
          flag_value(args, "--webpush-file"),
          source_config.webpush_file,
        )
      let source_attachments =
        prefer_option(
          flag_value(args, "--ntfy-attachments"),
          source_config.attachment_directory,
        )
      case cache, auth, webpush {
        None, None, None ->
          fail(
            "usage: notify migrate ntfy [--cache-file PATH] [--auth-file PATH] [--webpush-file PATH] [--ntfy-attachments DIR] [--dry-run]",
          )
        _, _, _ -> {
          let anonymous = case flag_value(args, "--ntfy-default-access") {
            Some(value) -> parse_permission(value)
            None ->
              Ok(source_config.default_access |> option.unwrap(acl.ReadWrite))
          }
          case anonymous {
            Error(_) ->
              fail(
                "invalid --ntfy-default-access; use deny, read, write, or read-write",
              )
            Ok(anonymous) -> {
              let destination_attachments = case source_attachments {
                None -> Ok(None)
                Some(_) ->
                  server.open_attachment_store(configuration)
                  |> result.map(Some)
              }
              case destination_attachments {
                Error(error) ->
                  fail(
                    "attachment destination error: " <> attachment_error(error),
                  )
                Ok(destination_attachments) -> {
                  let runtime.Clock(now) = runtime.system_clock()
                  let base_url = case configuration.base_url {
                    Some(value) -> value
                    None ->
                      "http://"
                      <> configuration.bind
                      <> ":"
                      <> int.to_string(configuration.port)
                  }
                  case
                    ntfy_migration.run(ntfy_migration.Options(
                      cache_file: cache,
                      auth_file: auth,
                      webpush_file: webpush,
                      attachment_directory: source_attachments,
                      destination_file: configuration.database_path,
                      destination_attachments:,
                      base_url:,
                      default_access: anonymous,
                      cache_duration_seconds: configuration.retention_seconds,
                      now: now(),
                      dry_run: has_flag(args, "--dry-run"),
                    ))
                  {
                    Error(error) -> fail(ntfy_migration.error_message(error))
                    Ok(report) -> print_ntfy_migration_report(report)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn with_ntfy_source_config(
  args: List(String),
  continue: fn(ntfy_migration.SourceConfig) -> Nil,
) -> Nil {
  case flag_value(args, "--ntfy-config") {
    None -> continue(ntfy_migration.SourceConfig(None, None, None, None, None))
    Some(path) ->
      case ntfy_migration.read_source_config(path) {
        Ok(config) -> continue(config)
        Error(error) -> fail(ntfy_migration.error_message(error))
      }
  }
}

fn prefer_option(first: Option(a), second: Option(a)) -> Option(a) {
  case first {
    Some(_) -> first
    None -> second
  }
}

fn print_ntfy_migration_report(report: ntfy_migration.Report) -> Nil {
  io.println(case report.dry_run {
    True -> "ntfy migration dry-run complete"
    False -> "ntfy migration complete"
  })
  print_migration_counts("messages", report.messages)
  print_migration_counts("users", report.users)
  print_migration_counts("tokens", report.tokens)
  print_migration_counts("ACL rules", report.acl_rules)
  print_migration_counts("Web Push subscriptions", report.webpush_subscriptions)
  print_migration_counts("attachments", report.attachments)
  list.each(report.source_digests, fn(source) {
    io.println("source_sha256\t" <> source.1 <> "\t" <> source.0)
  })
}

fn print_migration_counts(label: String, counts: ntfy_migration.Counts) -> Nil {
  io.println(
    label
    <> "\tscanned="
    <> int.to_string(counts.scanned)
    <> "\tmigrated="
    <> int.to_string(counts.migrated)
    <> "\tskipped="
    <> int.to_string(counts.skipped),
  )
}

fn with_access(args: List(String), continue: fn(access.Access) -> Nil) -> Nil {
  use configuration <- with_config(args)
  case open_identity(configuration) {
    Error(error) -> identity_failure(error)
    Ok(store) ->
      case access.managed(store) {
        Error(_) -> fail("Argon2id password subsystem is unavailable")
        Ok(control) ->
          case access.setup_required(control) {
            Ok(False) -> continue(control)
            Ok(True) -> fail("server setup is not complete")
            Error(error) -> access_failure(error)
          }
      }
  }
}

fn start_identity(
  configuration: config.Config,
  now: fn() -> Int,
) -> Result(#(identity.Store, Option(String)), identity.Error) {
  case configuration.database_backend {
    config.SQLite ->
      identity_sqlite.start(
        configuration.database_path,
        now,
        token.secure_entropy,
      )
      |> result.map(fn(started) {
        let identity_sqlite.Started(store, setup_token) = started
        #(store, setup_token)
      })
    config.PostgreSQL ->
      identity_postgres.start(
        server.postgres_config(configuration),
        now,
        token.secure_entropy,
      )
      |> result.map(fn(started) {
        let identity_postgres.Started(store, setup_token) = started
        #(store, setup_token)
      })
  }
}

fn open_identity(
  configuration: config.Config,
) -> Result(identity.Store, identity.Error) {
  case configuration.database_backend {
    config.SQLite -> identity_sqlite.open_store(configuration.database_path)
    config.PostgreSQL ->
      identity_postgres.open_store(server.postgres_config(configuration))
  }
}

fn open_message_storage(
  configuration: config.Config,
) -> Result(Storage, storage.Error) {
  case configuration.database_backend {
    config.SQLite -> sqlite.start(configuration.database_path)
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

fn with_config(args: List(String), continue: fn(config.Config) -> Nil) -> Nil {
  case config.load(config_arguments(args)) {
    Ok(configuration) -> continue(configuration)
    Error(error) -> fail("configuration error: " <> config.error_message(error))
  }
}

fn config_arguments(args: List(String)) -> List(String) {
  case args {
    [] -> []
    [flag, value, ..rest] ->
      case is_config_value_flag(flag) {
        True -> [flag, value, ..config_arguments(rest)]
        False ->
          case is_config_bool_flag(flag) {
            True -> [flag, ..config_arguments([value, ..rest])]
            False -> config_arguments([value, ..rest])
          }
      }
    [flag] ->
      case is_config_bool_flag(flag) {
        True -> [flag]
        False -> []
      }
  }
}

fn positional(args: List(String)) -> List(String) {
  case args {
    [] -> []
    [flag, value, ..rest] ->
      case is_value_flag(flag) {
        True -> positional(rest)
        False ->
          case is_bool_flag(flag) {
            True -> positional([value, ..rest])
            False -> [flag, ..positional([value, ..rest])]
          }
      }
    [flag] ->
      case is_bool_flag(flag) {
        True -> []
        False -> [flag]
      }
  }
}

fn is_config_value_flag(flag: String) -> Bool {
  list.contains(
    [
      "--config",
      "--listen-host",
      "--port",
      "--base-url",
      "--database",
      "--database-backend",
      "--postgres-host",
      "--postgres-port",
      "--postgres-database",
      "--postgres-username",
      "--postgres-password",
      "--postgres-ssl",
      "--node-id",
      "--retention-seconds",
      "--max-request-bytes",
      "--rate-limit-requests",
      "--rate-limit-subscriptions",
      "--rate-limit-topic-creations",
      "--rate-limit-auth-failures",
      "--rate-limit-attachment-mebibytes",
      "--rate-limit-attachment-uploads",
      "--rate-limit-window",
      "--attachment-backend",
      "--attachment-dir",
      "--attachment-file-size",
      "--attachment-total-size",
      "--attachment-retention-seconds",
      "--s3-endpoint",
      "--s3-bucket",
      "--s3-region",
      "--s3-access-key",
      "--s3-secret-key",
      "--s3-path-style",
      "--webpush-public-key",
      "--webpush-private-key",
      "--webpush-subscriber",
      "--relay-url",
      "--relay-token",
      "--upstream-base-url",
      "--upstream-access-token",
      "--tls-certificate",
      "--tls-key",
      "--trusted-proxies",
      "--log-format",
    ],
    flag,
  )
}

fn is_config_bool_flag(flag: String) -> Bool {
  list.contains(["--dev-open", "--cluster"], flag)
}

fn is_value_flag(flag: String) -> Bool {
  is_config_value_flag(flag)
  || list.contains(
    [
      "--password",
      "--username",
      "--anonymous-access",
      "--label",
      "--expires",
      "--server",
      "--token",
      "--since",
      "--from-dir",
      "--source-dir",
      "--to",
      "--cache-file",
      "--auth-file",
      "--webpush-file",
      "--ntfy-attachments",
      "--ntfy-default-access",
      "--ntfy-config",
    ],
    flag,
  )
}

fn is_bool_flag(flag: String) -> Bool {
  is_config_bool_flag(flag) || list.contains(["--admin", "--dry-run"], flag)
}

fn flag_value(args: List(String), wanted: String) -> Option(String) {
  case args {
    [] -> None
    [flag, value, ..] if flag == wanted -> Some(value)
    [_, ..rest] -> flag_value(rest, wanted)
  }
}

fn has_flag(args: List(String), wanted: String) -> Bool {
  case args {
    [] -> False
    [flag, ..] if flag == wanted -> True
    [_, ..rest] -> has_flag(rest, wanted)
  }
}

fn password_value(args: List(String)) -> Result(String, Nil) {
  case flag_value(args, "--password"), cli_getenv("NOTIFY_PASSWORD") {
    Some(value), _ -> Ok(value)
    None, Ok(value) -> Ok(value)
    None, Error(_) -> read_password("Password: ")
  }
}

fn authorization_headers(args: List(String)) -> List(#(String, String)) {
  case flag_value(args, "--token"), cli_getenv("NOTIFY_TOKEN") {
    Some(value), _ | None, Ok(value) -> [#("authorization", "Bearer " <> value)]
    None, Error(_) -> []
  }
}

fn server_url(args: List(String), configuration: config.Config) -> String {
  let base = case flag_value(args, "--server"), configuration.base_url {
    Some(value), _ -> value
    None, Some(value) -> value
    None, None ->
      "http://"
      <> configuration.bind
      <> ":"
      <> int.to_string(configuration.port)
  }
  case string.ends_with(base, "/") {
    True -> string.drop_end(base, 1)
    False -> base
  }
}

fn parse_permission(value: String) -> Result(acl.Permission, Nil) {
  case string.lowercase(value) {
    "deny" | "none" -> Ok(acl.Deny)
    "read" | "ro" -> Ok(acl.ReadOnly)
    "write" | "wo" -> Ok(acl.WriteOnly)
    "read-write" | "rw" -> Ok(acl.ReadWrite)
    _ -> Error(Nil)
  }
}

fn print_rule(rule: acl.Rule) -> Nil {
  io.println(
    rule.username
    <> "\t"
    <> rule.topic_pattern
    <> "\t"
    <> permission_string(rule.permission),
  )
}

fn print_bytes(value: BitArray) -> Nil {
  case bit_array.to_string(value) {
    Ok(value) -> io.print(value)
    Error(_) -> fail("server response was not UTF-8")
  }
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.Admin -> "admin"
    acl.User -> "user"
  }
}

fn permission_string(permission: acl.Permission) -> String {
  case permission {
    acl.Deny -> "deny"
    acl.ReadOnly -> "read"
    acl.WriteOnly -> "write"
    acl.ReadWrite -> "read-write"
  }
}

fn expiry_string(expires: Option(Int)) -> String {
  case expires {
    Some(value) -> int.to_string(value)
    None -> "never"
  }
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn attachment_migration_error(error: attachment_migration.Error) -> String {
  case error {
    attachment_migration.Source(error) -> "source " <> attachment_error(error)
    attachment_migration.Destination(error) ->
      "destination " <> attachment_error(error)
    attachment_migration.IntegrityMismatch(expected, actual) ->
      "content hash mismatch; expected " <> expected <> ", got " <> actual
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
      "quota exceeded (" <> int.to_string(limit) <> " bytes)"
    attachment_store.NotFound -> "object not found"
    attachment_store.InvalidRange -> "invalid byte range"
    attachment_store.Unavailable(detail) -> detail
  }
}

fn transpose(value: Option(Result(a, e))) -> Result(Option(a), e) {
  case value {
    None -> Ok(None)
    Some(Ok(value)) -> Ok(Some(value))
    Some(Error(error)) -> Error(error)
  }
}

fn identity_failure(error: identity.Error) -> Nil {
  case error {
    identity.Unavailable(detail)
    | identity.Conflict(detail)
    | identity.Corrupt(detail) -> fail("identity storage error: " <> detail)
    identity.NotFound -> fail("identity record not found")
    identity.InvalidSetupToken -> fail("invalid setup token")
    identity.SetupAlreadyComplete -> fail("setup is already complete")
  }
}

fn access_failure(error: access.Error) -> Nil {
  case error {
    access.InvalidUsername -> fail("invalid username")
    access.InvalidTopicPattern -> fail("invalid topic pattern")
    access.InvalidTokenLabel -> fail("token label is too long")
    access.LastAdmin -> fail("cannot delete the last administrator")
    access.InvalidCredentials -> fail("invalid credentials")
    access.PasswordError(_) -> fail("password must be 12-1024 characters")
    access.IdentityError(error) -> identity_failure(error)
    access.SetupRequired -> fail("server setup is required")
    access.InvalidSetupToken -> fail("invalid setup token")
    access.SetupAlreadyComplete -> fail("setup is already complete")
    access.TokenError(_) -> fail("secure token generation failed")
  }
}

fn fail(message: String) -> Nil {
  io.println("ERROR " <> message)
  exit_failure()
}

@external(erlang, "notify_ffi", "getenv")
fn cli_getenv(name: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "read_password")
fn read_password(prompt: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(#(Int, BitArray), String)

@external(erlang, "notify_ffi", "generate_vapid_keys")
fn generate_vapid_keys() -> Result(#(String, String), String)

@external(erlang, "notify_ffi", "exit_failure")
fn exit_failure() -> Nil
