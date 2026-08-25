import gleam/io
import gleam/list
import notify/cli
import notify/config
import notify/server

pub fn main() -> Nil {
  case argv() {
    [] | ["help"] | ["--help"] | ["-h"] -> print_help()
    ["serve", ..args] -> serve(args)
    ["config", "check", ..args] -> config_check(args)
    ["config", "show", ..args] -> config_show(args)
    ["doctor", ..args] -> cli.doctor(args)
    ["db", action, ..args] -> cli.db(action, args)
    ["setup", ..args] -> cli.setup(args)
    ["publish", ..args] -> cli.publish(args)
    ["subscribe", ..args] -> cli.subscribe(args)
    ["user", action, ..args] -> cli.user(action, args)
    ["token", action, ..args] -> cli.token_command(action, args)
    ["access", action, ..args] -> cli.access_command(action, args)
    ["webpush", "keys", ..] -> cli.webpush_keys()
    ["attachments", action, ..args] -> cli.attachments(action, args)
    ["migrate", "ntfy", ..args] -> cli.migrate_ntfy(args)
    [command, ..] -> {
      io.println("unknown command: " <> command)
      print_help()
    }
  }
}

fn serve(args: List(String)) -> Nil {
  case config.load(args) {
    Error(error) ->
      io.println("configuration error: " <> config.error_message(error))
    Ok(configuration) ->
      case server.start(configuration) {
        Error(error) ->
          io.println("startup error: " <> server.error_message(error))
        Ok(started) -> {
          case wait_for_shutdown_signal() {
            Ok(_) -> {
              io.println("shutdown signal received; draining connections")
              case server.stop(started, 30_000) {
                True -> io.println("shutdown complete")
                False ->
                  io.println("shutdown deadline exceeded; workers stopped")
              }
            }
            Error(detail) -> {
              io.println("shutdown handler error: " <> detail)
              let _ = server.stop(started, 30_000)
              Nil
            }
          }
        }
      }
  }
}

fn config_check(args: List(String)) -> Nil {
  case config.load(args) {
    Ok(_) -> io.println("configuration is valid")
    Error(error) ->
      io.println("configuration error: " <> config.error_message(error))
  }
}

fn config_show(args: List(String)) -> Nil {
  case config.load(args) {
    Ok(configuration) -> io.print(config.to_toml(configuration))
    Error(error) ->
      io.println("configuration error: " <> config.error_message(error))
  }
}

fn print_help() -> Nil {
  [
    "Notify — ntfy-compatible notification server",
    "",
    "Usage: notify <command> [options]",
    "",
    "Commands:",
    "  serve                    Start the HTTP server",
    "  setup                    Explain the one-time setup flow",
    "  publish|subscribe        Use the ntfy-compatible HTTP API",
    "  user add|list|delete|password",
    "  token create|list|revoke",
    "  access grant|revoke|list",
    "  webpush keys             Generate VAPID P-256 keys",
    "  attachments migrate      Copy filesystem attachments to configured storage",
    "  migrate ntfy             Import ntfy v2.27.0 SQLite data",
    "  doctor                   Diagnose configuration and SQLite",
    "  config check|show        Validate or print effective config",
    "  db migrate|status        Apply or inspect database migrations",
    "  db backup|verify|restore Create and verify SQLite recovery snapshots",
    "",
    "Serve options:",
    "  --config PATH            TOML file (default: notify.toml)",
    "  --listen-host HOST       Bind address (default: 127.0.0.1)",
    "  --port PORT              HTTP port (default: 8080)",
    "  --database PATH          SQLite path (default: data/notify.db)",
    "  --retention-seconds N    Message cache retention (default: 43200)",
    "  --max-request-bytes N    Reject larger request bodies",
    "  --template-dir PATH       Custom .yml message templates",
    "  --rate-limit-requests N  Requests allowed per client window",
    "  --rate-limit-subscriptions N  Subscription attempts per client window",
    "  --rate-limit-topic-creations N Publish/topic creation attempts per window",
    "  --rate-limit-auth-failures N Authentication failures per client window",
    "  --rate-limit-attachment-mebibytes N Attachment MiB per client window",
    "  --rate-limit-attachment-uploads N Attachment uploads per client window",
    "  --rate-limit-window N    Rate-limit window in seconds",
    "  --log-format human|json  Request log output format",
    "  --dev-open               Explicit localhost-only development mode",
  ]
  |> list.each(io.println)
}

@external(erlang, "notify_ffi", "argv")
fn argv() -> List(String)

@external(erlang, "notify_ffi", "wait_for_shutdown_signal")
fn wait_for_shutdown_signal() -> Result(Nil, String)
