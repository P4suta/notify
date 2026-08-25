import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Head, Options, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import notify/access
import notify/attachment_store
import notify/audit
import notify/core/acl
import notify/core/action as action_parser
import notify/core/delay
import notify/core/message.{type Draft, type Message}
import notify/core/message_json
import notify/core/topic
import notify/delivery
import notify/http/admin
import notify/http/audit_log
import notify/http/auth as http_auth
import notify/http/compat_account
import notify/http/filter_params
import notify/http/parameter as http_parameter
import notify/runtime.{type Runtime}
import notify/service
import notify/since
import notify/storage
import notify/template as message_template
import notify/webpush

const ntfy_docs = "https://ntfy.sh/docs/publish/"

const auth_docs = "https://ntfy.sh/docs/publish/#authentication"

pub fn handle(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  let reply = case admin.route(req, runtime) {
    Some(reply) -> reply
    None ->
      case compat_account.route(req, runtime) {
        Some(reply) -> reply
        None -> handle_protocol(req, runtime)
      }
  }
  response.set_header(reply, "x-request-id", correlation_id(req))
}

pub fn correlation_id(req: Request(body)) -> String {
  case request.get_header(req, "x-request-id") {
    Ok(value) ->
      case is_safe_request_id(value) {
        True -> value
        False -> random_id()
      }
    Error(_) -> random_id()
  }
}

fn is_safe_request_id(value: String) -> Bool {
  let length = string.length(value)
  length >= 1
  && length <= 64
  && value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.",
      character,
    )
  })
}

fn handle_protocol(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  let segments = request.path_segments(req)
  case req.method, segments {
    Options, _ -> cors_options_response()
    Get, [] -> public_asset("index.html", "text/html; charset=utf-8")
    Get, ["setup"] -> public_asset("setup.html", "text/html; charset=utf-8")
    Get, ["notify_web.js"] ->
      public_asset("notify_web.js", "text/javascript; charset=utf-8")
    Get, ["setup.js"] ->
      public_asset("setup.js", "text/javascript; charset=utf-8")
    Get, ["styles.css"] -> public_asset("styles.css", "text/css; charset=utf-8")
    Get, ["manifest.webmanifest"] ->
      public_asset("manifest.webmanifest", "application/manifest+json")
    Get, ["icon.svg"] -> public_asset("icon.svg", "image/svg+xml")
    Get, ["icon-192.png"] -> public_asset("icon-192.png", "image/png")
    Get, ["icon-512.png"] -> public_asset("icon-512.png", "image/png")
    Get, ["api", "openapi.json"] ->
      public_asset("openapi.json", "application/json; charset=utf-8")
    Get, ["sw.js"] -> public_asset("sw.js", "text/javascript; charset=utf-8")
    Get, ["healthz"] -> liveness()
    Get, ["readyz"] -> readiness(runtime)
    Get, ["metrics"] -> metrics(runtime)
    Get, ["v1", "health"] -> health(runtime)
    Get, ["v1", "version"] -> version()
    Get, ["v1", "stats"] -> stats(runtime)
    Get, ["v1", "config"] -> compatibility_config(runtime)
    Post, ["v1", "webpush"] -> webpush_update(req, runtime)
    Delete, ["v1", "webpush"] -> webpush_delete(req, runtime)
    Get, ["file", topic, key, filename] ->
      download(req, topic, key, Some(filename), False, runtime)
    Head, ["file", topic, key, filename] ->
      download(req, topic, key, Some(filename), True, runtime)
    Get, ["file", topic, key] -> download(req, topic, key, None, False, runtime)
    Head, ["file", topic, key] -> download(req, topic, key, None, True, runtime)
    Post, ["api", "v1", "setup"] -> setup(req, runtime)
    Put, [topic, sequence_id, action] if action == "clear" || action == "read" ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_control(
          req,
          topic,
          sequence_id,
          message.MessageClearEvent,
          runtime,
        )
      })
    Get, [topic, sequence_id, action] if action == "clear" || action == "read" ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_control(
          req,
          topic,
          sequence_id,
          message.MessageClearEvent,
          runtime,
        )
      })
    Delete, [topic, sequence_id] ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_control(
          req,
          topic,
          sequence_id,
          message.MessageDeleteEvent,
          runtime,
        )
      })
    Get, [topic, sequence_id, "delete"] ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_control(
          req,
          topic,
          sequence_id,
          message.MessageDeleteEvent,
          runtime,
        )
      })
    Post, [topic, sequence_id] ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_update(req, topic, sequence_id, runtime)
      })
    Put, [topic, sequence_id] ->
      with_valid_sequence_path(sequence_id, fn() {
        publish_update(req, topic, sequence_id, runtime)
      })
    Post, [topic] -> publish_plaintext(req, topic, runtime)
    Put, [topic] -> publish_plaintext(req, topic, runtime)
    Post, [] -> publish_json(req, runtime)
    Put, [] -> publish_json(req, runtime)
    Get, [topic, action]
      if action == "publish" || action == "send" || action == "trigger"
    -> publish_webhook(req, topic, runtime)
    Get, [topics, "json"] -> poll(req, topics, JsonFormat, runtime)
    Get, [topics, "raw"] -> poll(req, topics, RawFormat, runtime)
    Get, [topics, "sse"] -> poll(req, topics, SseFormat, runtime)
    Get, [topics, "auth"] -> topic_auth(req, topics, runtime)
    Head, ["v1", "health"] -> empty_response(200)
    _, _ -> ntfy_error(404, 40_401, "page not found", ntfy_docs)
  }
}

type SetupRequest {
  SetupRequest(
    token: String,
    username: String,
    password: String,
    anonymous_access: acl.Permission,
  )
}

fn setup(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case body_or_error(req) {
    Error(_) ->
      problem(400, "Invalid setup request", "Request body is not UTF-8")
    Ok(body) ->
      case json.parse(body, setup_decoder()) {
        Error(_) ->
          problem(
            400,
            "Invalid setup request",
            "Expected token, username, password, and anonymous_access",
          )
        Ok(setup) -> {
          case
            audit_log.append(
              req,
              runtime,
              "anonymous",
              audit.SetupComplete,
              None,
              audit.Attempted,
              None,
            )
          {
            Error(_) ->
              problem(
                503,
                "Audit unavailable",
                "The setup audit attempt could not be persisted",
              )
            Ok(_) -> {
              let runtime.Clock(now) = runtime.clock
              let runtime.IdGenerator(next_id) = runtime.ids
              let reply = case
                access.complete_setup(
                  runtime.access,
                  setup.token,
                  "u_" <> next_id(),
                  setup.username,
                  setup.password,
                  setup.anonymous_access,
                  now(),
                )
              {
                Ok(user) ->
                  json_response(
                    201,
                    json.object([
                      #("id", json.string(user.id)),
                      #("username", json.string(user.username)),
                      #("role", json.string("admin")),
                    ])
                      |> json.to_string,
                  )
                Error(access.InvalidSetupToken) ->
                  problem(
                    403,
                    "Invalid setup token",
                    "The setup URL is invalid or expired",
                  )
                Error(access.SetupAlreadyComplete) ->
                  problem(
                    409,
                    "Setup already complete",
                    "The one-time setup was already used",
                  )
                Error(access.InvalidUsername) ->
                  problem(
                    400,
                    "Invalid username",
                    "Use 1-64 safe username characters",
                  )
                Error(access.PasswordError(_)) ->
                  problem(
                    400,
                    "Invalid password",
                    "Password must be 12-1024 characters",
                  )
                Error(_) ->
                  problem(
                    503,
                    "Setup unavailable",
                    "Identity storage is unavailable",
                  )
              }
              case
                audit_log.append(
                  req,
                  runtime,
                  case reply.status == 201 {
                    True -> setup.username
                    False -> "anonymous"
                  },
                  audit.SetupComplete,
                  None,
                  audit_log.outcome_for_status(reply.status),
                  Some(reply.status),
                )
              {
                Ok(_) -> reply
                Error(_) ->
                  response.set_header(
                    reply,
                    "x-notify-audit-status",
                    "incomplete",
                  )
              }
            }
          }
        }
      }
  }
}

fn setup_decoder() -> decode.Decoder(SetupRequest) {
  use token <- decode.field("token", decode.string)
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  use anonymous_access <- decode.optional_field(
    "anonymous_access",
    acl.Deny,
    permission_decoder(),
  )
  decode.success(SetupRequest(token:, username:, password:, anonymous_access:))
}

type WebPushRequest {
  WebPushRequest(
    endpoint: String,
    auth: String,
    p256dh: String,
    topics: List(String),
  )
}

type WebPushDeleteRequest {
  WebPushDeleteRequest(endpoint: String)
}

fn webpush_update(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case runtime.webpush {
    None -> ntfy_error(404, 40_401, "page not found", ntfy_docs)
    Some(configured) ->
      case body_or_error(req) {
        Error(_) -> webpush_malformed()
        Ok(body) ->
          case json.parse(body, webpush_decoder()) {
            Error(_) -> webpush_malformed()
            Ok(parsed) -> {
              let runtime.Clock(now) = runtime.clock
              let runtime.IdGenerator(next_id) = runtime.ids
              let subscriber_ip =
                request.get_header(req, "x-notify-client-ip")
                |> result.unwrap("unknown")
              let candidate =
                webpush.NewSubscription(
                  id: "wps_" <> next_id(),
                  endpoint: parsed.endpoint,
                  auth: parsed.auth,
                  p256dh: parsed.p256dh,
                  topics: parsed.topics,
                  user_id: None,
                  subscriber_ip: subscriber_ip,
                  now: now(),
                )
              case webpush.validate(candidate) {
                Error(webpush.UnknownEndpoint) ->
                  ntfy_error(
                    400,
                    40_039,
                    "invalid request: web push endpoint unknown",
                    "",
                  )
                Error(webpush.TooManyTopics) -> webpush_too_many_topics()
                Error(_) -> webpush_malformed()
                Ok(_) ->
                  case list.try_map(parsed.topics, topic.parse) {
                    Error(_) -> webpush_malformed()
                    Ok(topics) ->
                      with_webpush_authorization(
                        req,
                        topics,
                        runtime,
                        fn(principal) {
                          let user_id = case principal {
                            acl.Anonymous -> None
                            acl.Authenticated(username, _) -> Some(username)
                          }
                          case
                            configured.store.upsert(
                              webpush.NewSubscription(..candidate, user_id:),
                            )
                          {
                            Ok(_) -> json_response(200, "{\"success\":true}")
                            Error(webpush.UnknownEndpoint) ->
                              ntfy_error(
                                400,
                                40_039,
                                "invalid request: web push endpoint unknown",
                                "",
                              )
                            Error(webpush.TooManyTopics) ->
                              webpush_too_many_topics()
                            Error(webpush.InvalidSubscription) ->
                              webpush_malformed()
                            Error(webpush.TooManySubscriptions) ->
                              ntfy_error(
                                429,
                                42_901,
                                "limit reached: too many web push subscriptions",
                                "",
                              )
                            Error(_) ->
                              ntfy_error(
                                500,
                                50_001,
                                "internal server error",
                                "",
                              )
                          }
                        },
                      )
                  }
              }
            }
          }
      }
  }
}

fn webpush_delete(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case http_auth.uses_session(req) && !http_auth.valid_csrf(req) {
    True -> ntfy_error(403, 40_303, "CSRF token required", ntfy_docs)
    False ->
      case runtime.webpush {
        None -> ntfy_error(404, 40_401, "page not found", ntfy_docs)
        Some(configured) ->
          case body_or_error(req) {
            Error(_) -> webpush_malformed()
            Ok(body) ->
              case json.parse(body, webpush_delete_decoder()) {
                Error(_) -> webpush_malformed()
                Ok(parsed) ->
                  case string.is_empty(parsed.endpoint) {
                    True -> webpush_malformed()
                    False ->
                      case configured.store.remove_endpoint(parsed.endpoint) {
                        Ok(_) -> json_response(200, "{\"success\":true}")
                        Error(_) ->
                          ntfy_error(500, 50_001, "internal server error", "")
                      }
                  }
              }
          }
      }
  }
}

fn with_webpush_authorization(
  req: Request(BitArray),
  topics: List(topic.Topic),
  runtime: Runtime,
  next: fn(acl.Principal) -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case http_auth.uses_session(req) && !http_auth.valid_csrf(req) {
    True -> ntfy_error(403, 40_303, "CSRF token required", ntfy_docs)
    False ->
      case http_auth.check(req, runtime.access, topics, acl.Read, now()) {
        Ok(principal) -> next(principal)
        Error(http_auth.MalformedCredentials)
        | Error(http_auth.Unauthenticated) ->
          ntfy_error(401, 40_101, "unauthorized", auth_docs)
          |> response.set_header("www-authenticate", "Basic realm=\"notify\"")
        Error(http_auth.Forbidden) ->
          ntfy_error(403, 40_303, "forbidden", ntfy_docs)
        Error(http_auth.SetupRequired) ->
          ntfy_error(503, 50_301, "server setup is required", ntfy_docs)
        Error(http_auth.Unavailable) ->
          ntfy_error(503, 50_301, "authorization unavailable", ntfy_docs)
      }
  }
}

fn webpush_decoder() -> decode.Decoder(WebPushRequest) {
  use endpoint <- decode.field("endpoint", decode.string)
  use auth <- decode.field("auth", decode.string)
  use p256dh <- decode.field("p256dh", decode.string)
  use topics <- decode.field("topics", decode.list(decode.string))
  decode.success(WebPushRequest(endpoint:, auth:, p256dh:, topics:))
}

fn webpush_delete_decoder() -> decode.Decoder(WebPushDeleteRequest) {
  use endpoint <- decode.field("endpoint", decode.string)
  decode.success(WebPushDeleteRequest(endpoint:))
}

fn webpush_malformed() -> Response(BitArray) {
  ntfy_error(400, 40_038, "invalid request: web push payload malformed", "")
}

fn webpush_too_many_topics() -> Response(BitArray) {
  ntfy_error(
    400,
    40_040,
    "invalid request: too many web push topic subscriptions",
    "",
  )
}

fn permission_decoder() -> decode.Decoder(acl.Permission) {
  use value <- decode.then(decode.string)
  case string.lowercase(value) {
    "deny" | "deny-all" | "none" -> decode.success(acl.Deny)
    "read" | "read-only" | "ro" -> decode.success(acl.ReadOnly)
    "write" | "write-only" | "wo" -> decode.success(acl.WriteOnly)
    "read-write" | "rw" -> decode.success(acl.ReadWrite)
    _ -> decode.failure(acl.Deny, expected: "ntfy access permission")
  }
}

fn publish_update(
  req: Request(BitArray),
  topic_name: String,
  sequence_id: String,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic_or_error(topic_name) {
    Error(response) -> response
    Ok(parsed_topic) ->
      with_authorization(req, [parsed_topic], acl.Write, runtime, fn() {
        case body_or_error(req) {
          Error(response) -> response
          Ok(body) -> {
            message.plaintext_draft(parsed_topic, body)
            |> apply_template_and_publish_parameters(
              req,
              body,
              runtime.template_directory,
            )
            |> result.map(fn(draft) {
              message.Draft(..draft, sequence_id: Some(sequence_id))
            })
            |> publish_parameter_result(runtime)
          }
        }
      })
  }
}

fn with_valid_sequence_path(
  sequence_id: String,
  handler: fn() -> Response(BitArray),
) -> Response(BitArray) {
  case message.valid_sequence_id(sequence_id) {
    True -> handler()
    False -> page_not_found()
  }
}

fn publish_control(
  req: Request(BitArray),
  topic_name: String,
  sequence_id: String,
  event: message.Event,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic_or_error(topic_name) {
    Error(response) -> response
    Ok(parsed_topic) ->
      with_authorization(req, [parsed_topic], acl.Write, runtime, fn() {
        case
          service.publish_control(parsed_topic, event, sequence_id, runtime)
        {
          Ok(control) ->
            json_response(200, message_json.encode(control) |> json.to_string)
          Error(service.InvalidMessage(_)) ->
            ntfy_error(
              400,
              40_049,
              "invalid request: sequence ID invalid",
              "https://ntfy.sh/docs/publish/#updating-deleting-notifications",
            )
          Error(service.InvalidDelay(_)) ->
            ntfy_error(400, 40_007, "invalid delay", ntfy_docs)
          Error(service.Persistence(_))
          | Error(service.Delivery(_))
          | Error(service.WebPush(_)) ->
            ntfy_error(
              503,
              50_301,
              "temporarily unavailable: event was not stored",
              ntfy_docs,
            )
        }
      })
  }
}

fn publish_plaintext(
  req: Request(BitArray),
  topic_name: String,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic_or_error(topic_name) {
    Error(response) -> response
    Ok(parsed_topic) ->
      with_authorization(req, [parsed_topic], acl.Write, runtime, fn() {
        case
          param(req, ["x-filename", "filename", "file", "f"]),
          param(req, ["x-attach", "attach", "a"])
        {
          Some(filename), None ->
            publish_local_attachment(req, parsed_topic, filename, runtime)
          _, _ ->
            case body_or_error(req) {
              Error(response) -> response
              Ok(body) -> {
                let body = case string.is_empty(body) {
                  True -> "triggered"
                  False -> body
                }
                message.plaintext_draft(parsed_topic, body)
                |> publish_with_template_source(req, body, runtime)
              }
            }
        }
      })
  }
}

fn publish_local_attachment(
  req: Request(BitArray),
  parsed_topic: topic.Topic,
  filename: String,
  runtime: Runtime,
) -> Response(BitArray) {
  let body =
    param(req, ["x-message", "message", "m"])
    |> option.unwrap("You received a file: " <> filename)
  case
    valid_filename(filename),
    runtime.attachments,
    message.plaintext_draft(parsed_topic, body)
    |> apply_publish_parameters(req)
  {
    False, _, _ ->
      ntfy_error(400, 40_007, "invalid attachment filename", ntfy_docs)
    _, _, Error(error) -> publish_parameter_error(error)
    True, None, _ ->
      ntfy_error(400, 40_007, "local attachments are disabled", ntfy_docs)
    True, Some(store), Ok(draft) -> {
      let runtime.Clock(now) = runtime.clock
      let expires = now() + runtime.attachment_retention_seconds
      case
        attachment_store.put_in_chunks(
          store,
          attachment_store.Upload(req.body, expires:),
          1_048_576,
        )
      {
        Error(attachment_store.TooLarge(_, _)) ->
          ntfy_error(413, 41_301, "attachment too large", ntfy_docs)
        Error(attachment_store.QuotaExceeded(_)) ->
          ntfy_error(507, 50_701, "attachment quota exceeded", ntfy_docs)
        Error(_) ->
          ntfy_error(503, 50_301, "attachment storage unavailable", ntfy_docs)
        Ok(stored) -> {
          let attachment =
            message.Attachment(
              name: filename,
              url: attachment_url(runtime, parsed_topic, stored.key, filename),
              mime_type: request.get_header(req, "content-type")
                |> option.from_result,
              size: Some(stored.size),
              expires: Some(stored.expires),
            )
          message.Draft(..draft, attachment: Some(attachment))
          |> publish_draft(runtime)
        }
      }
    }
  }
}

fn attachment_url(
  runtime: Runtime,
  attached_topic: topic.Topic,
  key: String,
  filename: String,
) -> String {
  let base = case string.ends_with(runtime.attachment_base_url, "/") {
    True -> string.drop_end(runtime.attachment_base_url, 1)
    False -> runtime.attachment_base_url
  }
  base
  <> "/file/"
  <> topic.to_string(attached_topic)
  <> "/"
  <> key
  <> "/"
  <> uri.percent_encode(filename)
}

fn valid_filename(filename: String) -> Bool {
  !string.is_empty(filename)
  && string.length(filename) <= 255
  && !string.contains(filename, "/")
  && !string.contains(filename, "\\")
  && !string.contains(filename, "\u{0000}")
}

fn download(
  req: Request(BitArray),
  topic_name: String,
  key: String,
  filename: Option(String),
  head_only: Bool,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic_or_error(topic_name), runtime.attachments {
    Error(response), _ -> response
    _, None -> ntfy_error(404, 40_401, "attachment not found", ntfy_docs)
    Ok(parsed_topic), Some(store) ->
      with_authorization(req, [parsed_topic], acl.Read, runtime, fn() {
        case attachment_store.valid_content_key(key) {
          False -> ntfy_error(404, 40_401, "attachment not found", ntfy_docs)
          True ->
            case runtime.storage.has_attachment(parsed_topic, key) {
              Ok(False) ->
                ntfy_error(404, 40_401, "attachment not found", ntfy_docs)
              Error(_) ->
                ntfy_error(
                  503,
                  50_301,
                  "attachment storage unavailable",
                  ntfy_docs,
                )
              Ok(True) ->
                case store.head(key) {
                  Error(attachment_store.NotFound) ->
                    ntfy_error(404, 40_401, "attachment not found", ntfy_docs)
                  Error(_) ->
                    ntfy_error(
                      503,
                      50_301,
                      "attachment storage unavailable",
                      ntfy_docs,
                    )
                  Ok(metadata) -> {
                    let etag = "\"" <> key <> "\""
                    let filename = attachment_download_name(filename)
                    case
                      matches_etag(
                        request.get_header(req, "if-none-match"),
                        etag,
                      )
                    {
                      True ->
                        response.new(304)
                        |> response.set_header("etag", etag)
                        |> response.set_header(
                          "cache-control",
                          "private, max-age=3600",
                        )
                        |> response.set_body(<<>>)
                      False ->
                        case
                          parse_range(
                            request.get_header(req, "range"),
                            metadata.size,
                          )
                        {
                          Error(_) -> range_not_satisfiable(metadata.size)
                          Ok(range) ->
                            case head_only {
                              True ->
                                attachment_head_response(
                                  metadata.size,
                                  range,
                                  etag,
                                  filename,
                                )
                              False ->
                                case store.get(key, range) {
                                  Ok(download) ->
                                    attachment_download_response(
                                      download,
                                      range,
                                      etag,
                                      filename,
                                    )
                                  Error(attachment_store.InvalidRange) ->
                                    range_not_satisfiable(metadata.size)
                                  Error(attachment_store.NotFound) ->
                                    ntfy_error(
                                      404,
                                      40_401,
                                      "attachment not found",
                                      ntfy_docs,
                                    )
                                  Error(_) ->
                                    ntfy_error(
                                      503,
                                      50_301,
                                      "attachment storage unavailable",
                                      ntfy_docs,
                                    )
                                }
                            }
                        }
                    }
                  }
                }
            }
        }
      })
  }
}

fn matches_etag(header: Result(String, Nil), etag: String) -> Bool {
  case header {
    Error(_) -> False
    Ok(value) ->
      value
      |> string.split(",")
      |> list.map(string.trim)
      |> list.any(fn(candidate) {
        candidate == "*"
        || candidate == etag
        || {
          string.starts_with(candidate, "W/")
          && string.drop_start(candidate, 2) == etag
        }
      })
  }
}

fn attachment_download_name(filename: Option(String)) -> String {
  case filename {
    None -> "attachment"
    Some(encoded) -> {
      let filename = uri.percent_decode(encoded) |> result.unwrap(encoded)
      case valid_filename(filename) {
        True -> filename
        False -> "attachment"
      }
    }
  }
}

fn parse_range(
  header: Result(String, Nil),
  total: Int,
) -> Result(Option(attachment_store.ByteRange), Nil) {
  case header {
    Error(_) -> Ok(None)
    Ok(value) ->
      case string.split_once(string.trim(value), "=") {
        Ok(#("bytes", range)) ->
          case string.contains(range, ","), string.split_once(range, "-") {
            True, _ -> Error(Nil)
            False, Error(_) -> Error(Nil)
            False, Ok(#("", suffix)) ->
              case int.parse(suffix) {
                Ok(length) if length > 0 && length <= total ->
                  Ok(
                    Some(attachment_store.ByteRange(total - length, total - 1)),
                  )
                _ -> Error(Nil)
              }
            False, Ok(#(start, "")) ->
              case int.parse(start) {
                Ok(start) if start >= 0 && start < total ->
                  Ok(Some(attachment_store.ByteRange(start, total - 1)))
                _ -> Error(Nil)
              }
            False, Ok(#(start, end)) ->
              case int.parse(start), int.parse(end) {
                Ok(start), Ok(end)
                  if start >= 0 && end >= start && end < total
                -> Ok(Some(attachment_store.ByteRange(start, end)))
                _, _ -> Error(Nil)
              }
          }
        _ -> Error(Nil)
      }
  }
}

fn attachment_head_response(
  total: Int,
  range: Option(attachment_store.ByteRange),
  etag: String,
  filename: String,
) -> Response(BitArray) {
  let #(status, length) = case range {
    None -> #(200, total)
    Some(attachment_store.ByteRange(start, end)) -> #(206, end - start + 1)
  }
  let reply =
    response.new(status)
    |> response.set_header("content-type", "application/octet-stream")
    |> response.set_header("accept-ranges", "bytes")
    |> response.set_header("content-length", int.to_string(length))
    |> response.set_header("cache-control", "private, max-age=3600")
    |> response.set_header("x-content-type-options", "nosniff")
    |> attachment_identity_headers(etag, filename)
    |> response.set_body(<<>>)
  add_content_range(reply, range, total)
}

fn attachment_download_response(
  download: attachment_store.Download,
  range: Option(attachment_store.ByteRange),
  etag: String,
  filename: String,
) -> Response(BitArray) {
  let status = case range {
    None -> 200
    Some(_) -> 206
  }
  response.new(status)
  |> response.set_header("content-type", "application/octet-stream")
  |> response.set_header("accept-ranges", "bytes")
  |> response.set_header(
    "content-length",
    int.to_string(bit_array.byte_size(download.data)),
  )
  |> response.set_header("cache-control", "private, max-age=3600")
  |> response.set_header("x-content-type-options", "nosniff")
  |> attachment_identity_headers(etag, filename)
  |> response.set_body(download.data)
  |> add_content_range(range, download.total_size)
}

fn attachment_identity_headers(
  reply: Response(body),
  etag: String,
  filename: String,
) -> Response(body) {
  reply
  |> response.set_header("etag", etag)
  |> response.set_header(
    "content-disposition",
    "attachment; filename=\"attachment\"; filename*=UTF-8''"
      <> uri.percent_encode(filename),
  )
}

fn add_content_range(
  reply: Response(BitArray),
  range: Option(attachment_store.ByteRange),
  total: Int,
) -> Response(BitArray) {
  case range {
    None -> reply
    Some(attachment_store.ByteRange(start, end)) ->
      response.set_header(
        reply,
        "content-range",
        "bytes "
          <> int.to_string(start)
          <> "-"
          <> int.to_string(end)
          <> "/"
          <> int.to_string(total),
      )
  }
}

fn range_not_satisfiable(total: Int) -> Response(BitArray) {
  ntfy_error(416, 41_601, "requested range not satisfiable", ntfy_docs)
  |> response.set_header("content-range", "bytes */" <> int.to_string(total))
}

fn publish_json(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case body_or_error(req) {
    Error(response) -> response
    Ok(body) ->
      case message_json.decode_publish(body) {
        Ok(draft) ->
          with_authorization(req, [draft.topic], acl.Write, runtime, fn() {
            draft
            |> apply_template_and_publish_parameters(
              req,
              draft.message,
              runtime.template_directory,
            )
            |> publish_parameter_result(runtime)
          })
        Error(message_json.InvalidTopic(_)) -> invalid_topic()
        Error(message_json.InvalidPriority(_)) ->
          ntfy_error(400, 40_007, "invalid priority", ntfy_docs)
        Error(message_json.MalformedJson) ->
          ntfy_error(
            400,
            40_024,
            "invalid request: request body must be valid JSON",
            "",
          )
        Error(message_json.InvalidJson) ->
          ntfy_error(
            400,
            40_017,
            "invalid request: request body must be message JSON",
            "https://ntfy.sh/docs/publish/#publish-as-json",
          )
      }
  }
}

fn publish_webhook(
  req: Request(BitArray),
  topic_name: String,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic_or_error(topic_name) {
    Error(response) -> response
    Ok(parsed_topic) -> {
      with_authorization(req, [parsed_topic], acl.Write, runtime, fn() {
        let body =
          param(req, ["x-message", "message", "m"])
          |> option.unwrap("triggered")
        message.plaintext_draft(parsed_topic, body)
        |> publish_with_parameters(req, runtime)
      })
    }
  }
}

fn publish_draft(draft: Draft, runtime: Runtime) -> Response(BitArray) {
  case service.publish(draft, runtime) {
    Ok(message) ->
      json_response(200, message_json.encode(message) |> json.to_string)
    Error(service.InvalidMessage(message.InvalidSequenceId)) ->
      ntfy_error(
        400,
        40_049,
        "invalid request: sequence ID invalid",
        "https://ntfy.sh/docs/publish/#updating-deleting-notifications",
      )
    Error(service.InvalidMessage(_)) ->
      ntfy_error(400, 40_000, "invalid request", "")
    Error(service.InvalidDelay(error)) -> delay_error(error)
    Error(service.Persistence(_))
    | Error(service.Delivery(_))
    | Error(service.WebPush(_)) ->
      ntfy_error(
        503,
        50_301,
        "temporarily unavailable: message was not stored",
        ntfy_docs,
      )
  }
}

fn delay_error(error: delay.Error) -> Response(BitArray) {
  let docs = "https://ntfy.sh/docs/publish/#scheduled-delivery"
  case error {
    delay.InvalidDelay ->
      ntfy_error(
        400,
        40_004,
        "invalid delay parameter: unable to parse delay",
        docs,
      )
    delay.NotInFuture | delay.TooSoon(_) ->
      ntfy_error(
        400,
        40_005,
        "invalid delay parameter: too small, please refer to the docs",
        docs,
      )
    delay.TooFar(_) ->
      ntfy_error(
        400,
        40_006,
        "invalid delay parameter: too large, please refer to the docs",
        docs,
      )
  }
}

type PublishParameterError {
  InvalidPublishPriority
  InvalidPublishActions
  DelayedMessageWithoutCache
  TemplateSourceTooLarge
  TemplateSourceNotJson
  PublishTemplateTooLarge
  InvalidPublishTemplate
  DisallowedPublishTemplate
  PublishTemplateExecutionFailed
  PublishTemplateExecutionTimedOut
  TemplatedMessageTooLarge
  NamedPublishTemplateNotFound
  NamedPublishTemplateInvalid
}

fn publish_with_parameters(
  draft: Draft,
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  draft
  |> apply_template_and_publish_parameters(
    req,
    draft.message,
    runtime.template_directory,
  )
  |> publish_parameter_result(runtime)
}

fn publish_with_template_source(
  draft: Draft,
  req: Request(BitArray),
  source: String,
  runtime: Runtime,
) -> Response(BitArray) {
  draft
  |> apply_template_and_publish_parameters(
    req,
    source,
    runtime.template_directory,
  )
  |> publish_parameter_result(runtime)
}

fn publish_parameter_result(
  applied: Result(Draft, PublishParameterError),
  runtime: Runtime,
) -> Response(BitArray) {
  case applied {
    Ok(draft) -> publish_draft(draft, runtime)
    Error(error) -> publish_parameter_error(error)
  }
}

fn publish_parameter_error(error: PublishParameterError) -> Response(BitArray) {
  case error {
    InvalidPublishPriority ->
      ntfy_error(
        400,
        40_007,
        "invalid priority parameter",
        "https://ntfy.sh/docs/publish/#message-priority",
      )
    InvalidPublishActions ->
      ntfy_error(
        400,
        40_018,
        "invalid request: actions invalid",
        "https://ntfy.sh/docs/publish/#action-buttons",
      )
    DelayedMessageWithoutCache ->
      ntfy_error(
        400,
        40_002,
        "cannot disable cache for delayed message",
        ntfy_docs,
      )
    TemplateSourceTooLarge -> ntfy_error(413, 41_303, "JSON body too large", "")
    TemplateSourceNotJson ->
      template_error(
        40_042,
        "invalid request: message body must be JSON if templating is enabled",
      )
    PublishTemplateTooLarge ->
      template_error(40_056, "invalid request: template too large")
    InvalidPublishTemplate ->
      template_error(40_043, "invalid request: could not parse template")
    DisallowedPublishTemplate ->
      template_error(
        40_044,
        "invalid request: template contains disallowed function calls, e.g. template, call, define, or block",
      )
    PublishTemplateExecutionFailed ->
      template_error(40_045, "invalid request: template execution failed")
    PublishTemplateExecutionTimedOut ->
      template_error(40_055, "invalid request: template execution timed out")
    TemplatedMessageTooLarge ->
      template_error(
        40_041,
        "invalid request: message or title is too large after replacing template",
      )
    NamedPublishTemplateNotFound ->
      template_error(40_047, "invalid request: template file not found")
    NamedPublishTemplateInvalid ->
      template_error(40_048, "invalid request: template file invalid")
  }
}

fn template_error(code: Int, message: String) -> Response(BitArray) {
  ntfy_error(
    400,
    code,
    message,
    "https://ntfy.sh/docs/publish/#message-templating",
  )
}

type PollFormat {
  JsonFormat
  RawFormat
  SseFormat
}

fn poll(
  req: Request(BitArray),
  topic_names: String,
  format: PollFormat,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic.parse_many(topic_names) {
    Error(_) -> page_not_found()
    Ok(topics) ->
      with_authorization(req, topics, acl.Read, runtime, fn() {
        let runtime.Clock(now) = runtime.clock
        case
          since.parse(
            param(req, ["x-since", "since", "si"]),
            poll: True,
            now: now(),
          )
        {
          Error(_) ->
            ntfy_error(
              400,
              40_008,
              "invalid since parameter",
              "https://ntfy.sh/docs/subscribe/api/#fetch-cached-messages",
            )
          Ok(marker) -> {
            case filter_params.parse(req) {
              Error(_) ->
                ntfy_error(
                  400,
                  40_007,
                  "invalid priority parameter",
                  "https://ntfy.sh/docs/subscribe/api/#filter-messages",
                )
              Ok(criteria) -> {
                let query =
                  storage.Query(
                    topics:,
                    since: marker,
                    include_scheduled: truthy(
                      param(req, [
                        "x-scheduled",
                        "scheduled",
                        "sched",
                      ]),
                    ),
                    criteria:,
                  )
                case runtime.storage.query(query) {
                  Error(_) ->
                    ntfy_error(
                      503,
                      50_301,
                      "temporarily unavailable",
                      ntfy_docs,
                    )
                  Ok(messages) -> poll_response(messages, format)
                }
              }
            }
          }
        }
      })
  }
}

fn topic_auth(
  req: Request(BitArray),
  topic_names: String,
  runtime: Runtime,
) -> Response(BitArray) {
  case topic.parse_many(topic_names) {
    Error(_) -> page_not_found()
    Ok(topics) ->
      with_authorization(req, topics, acl.Read, runtime, fn() {
        json_response(200, "{\"success\":true}")
      })
  }
}

fn poll_response(
  messages: List(Message),
  format: PollFormat,
) -> Response(BitArray) {
  case format {
    JsonFormat ->
      messages
      |> list.map(fn(message) { message_json.encode(message) |> json.to_string })
      |> lines
      |> text_response(200, "application/x-ndjson; charset=utf-8")
    RawFormat ->
      messages
      |> list.map(fn(message) {
        message.message
        |> string.replace("\n", " ")
        |> string.replace("\r", " ")
      })
      |> lines
      |> text_response(200, "text/plain; charset=utf-8")
    SseFormat ->
      messages
      |> list.map(fn(message) {
        let encoded = message_json.encode(message) |> json.to_string
        "data: " <> encoded <> "\n"
      })
      |> list.intersperse("\n")
      |> string.concat
      |> with_final_newline(messages)
      |> text_response(200, "text/event-stream; charset=utf-8")
  }
}

fn lines(values: List(String)) -> String {
  case values {
    [] -> ""
    _ -> string.join(values, "\n") <> "\n"
  }
}

fn with_final_newline(value: String, messages: List(Message)) -> String {
  case messages {
    [] -> value
    _ -> value <> "\n"
  }
}

type PublishTemplateMode {
  PublishTemplateDisabled
  InlinePublishTemplate
  NamedPublishTemplate(String)
}

fn apply_template_and_publish_parameters(
  draft: Draft,
  req: Request(BitArray),
  source: String,
  template_directory: String,
) -> Result(Draft, PublishParameterError) {
  case publish_template_mode(req) {
    PublishTemplateDisabled -> apply_publish_parameters(draft, req)
    NamedPublishTemplate(name) -> {
      use with_parameters <- result.try(apply_named_template_parameters(
        draft,
        req,
      ))
      render_named_template(with_parameters, source, template_directory, name)
      |> result.map(ensure_template_message)
    }
    InlinePublishTemplate -> {
      let template_draft = message.Draft(..draft, message: "")
      use rendered <- result.try(render_inline_template(
        template_draft,
        req,
        source,
      ))
      apply_publish_parameter_values(
        rendered,
        req,
        title: None,
        body: None,
        priority: None,
      )
      |> result.map(ensure_template_message)
    }
  }
}

fn apply_named_template_parameters(
  draft: Draft,
  req: Request(BitArray),
) -> Result(Draft, PublishParameterError) {
  let template_draft = message.Draft(..draft, message: "")
  apply_publish_parameter_values(
    template_draft,
    req,
    title: option.or(draft.title, param(req, ["x-title", "title", "t"])),
    body: param(req, ["x-message", "message", "m"]),
    // v2.27 leaves this string unparsed in file mode. Only a priority field in
    // the selected template may replace the draft's already decoded value.
    priority: None,
  )
}

fn ensure_template_message(draft: Draft) -> Draft {
  case string.is_empty(draft.message) {
    True -> message.Draft(..draft, message: "triggered")
    False -> draft
  }
}

fn publish_template_mode(req: Request(body)) -> PublishTemplateMode {
  case param(req, ["x-template", "template", "tpl"]) {
    None -> PublishTemplateDisabled
    Some(value) ->
      case
        list.contains(
          ["yes", "1", "true", "no", "0", "false"],
          string.lowercase(value),
        )
      {
        True -> InlinePublishTemplate
        False -> NamedPublishTemplate(value)
      }
  }
}

fn render_named_template(
  draft: Draft,
  source: String,
  directory: String,
  name: String,
) -> Result(Draft, PublishParameterError) {
  case message_template.load_file(directory, name) {
    Ok(definition) -> render_template_definition(draft, source, definition)
    Error(message_template.FileInvalid) -> Error(NamedPublishTemplateInvalid)
    Error(message_template.FileNotFound) ->
      case message_template.render_builtin(source, name) {
        Ok(definition) -> apply_rendered_definition(draft, definition)
        Error(message_template.InvalidTemplate) ->
          Error(NamedPublishTemplateNotFound)
        Error(error) -> Error(template_render_error(error))
      }
  }
}

fn render_template_definition(
  draft: Draft,
  source: String,
  definition: message_template.Definition,
) -> Result(Draft, PublishParameterError) {
  let message_template.Definition(title:, message: body, priority:) = definition
  use rendered_message <- result.try(case body {
    None -> Ok(None)
    Some(value) ->
      message_template.render(source, value)
      |> result.map(Some)
      |> result.map_error(template_render_error)
  })
  use rendered_title <- result.try(render_optional_template(source, title))
  use rendered_priority <- result.try(render_optional_template(source, priority))
  apply_rendered_definition(
    draft,
    message_template.Definition(
      title: rendered_title,
      message: rendered_message,
      priority: rendered_priority,
    ),
  )
}

fn apply_rendered_definition(
  draft: Draft,
  definition: message_template.Definition,
) -> Result(Draft, PublishParameterError) {
  let message_template.Definition(title:, message: body, priority:) = definition
  let rendered_message = option.unwrap(body, draft.message)
  let rendered_title = option.or(title, draft.title)
  use rendered_priority <- result.try(case priority {
    Some(value) ->
      message.parse_priority(value)
      |> result.map_error(fn(_) { InvalidPublishPriority })
    None -> Ok(draft.priority)
  })
  case
    template_field_too_large(rendered_message),
    option.map(rendered_title, template_field_too_large)
    |> option.unwrap(False)
  {
    True, _ | _, True -> Error(TemplatedMessageTooLarge)
    False, False ->
      Ok(
        message.Draft(
          ..draft,
          message: rendered_message,
          title: rendered_title,
          priority: rendered_priority,
        ),
      )
  }
}

fn render_inline_template(
  draft: Draft,
  req: Request(body),
  source: String,
) -> Result(Draft, PublishParameterError) {
  let message_source =
    param(req, ["x-message", "message", "m"])
    |> option.unwrap(draft.message)
  let title_source =
    option.or(draft.title, param(req, ["x-title", "title", "t"]))
  let priority_source = param(req, ["x-priority", "priority", "prio", "p"])

  use rendered_message <- result.try(
    message_template.render(source, message_source)
    |> result.map_error(template_render_error),
  )
  use rendered_title <- result.try(render_optional_template(
    source,
    title_source,
  ))
  use rendered_priority <- result.try(render_optional_template(
    source,
    priority_source,
  ))
  use priority <- result.try(case rendered_priority {
    Some(value) ->
      message.parse_priority(value)
      |> result.map_error(fn(_) { InvalidPublishPriority })
    None -> Ok(draft.priority)
  })

  case
    template_field_too_large(rendered_message),
    option.map(rendered_title, template_field_too_large)
    |> option.unwrap(False)
  {
    True, _ | _, True -> Error(TemplatedMessageTooLarge)
    False, False ->
      Ok(
        message.Draft(
          ..draft,
          message: rendered_message,
          title: rendered_title,
          priority:,
        ),
      )
  }
}

fn render_optional_template(
  source: String,
  template: Option(String),
) -> Result(Option(String), PublishParameterError) {
  case template {
    None -> Ok(None)
    Some(template) ->
      message_template.render(source, template)
      |> result.map(Some)
      |> result.map_error(template_render_error)
  }
}

fn template_render_error(
  error: message_template.Error,
) -> PublishParameterError {
  case error {
    message_template.SourceTooLarge -> TemplateSourceTooLarge
    message_template.SourceNotJson -> TemplateSourceNotJson
    message_template.TemplateTooLarge -> PublishTemplateTooLarge
    message_template.InvalidTemplate -> InvalidPublishTemplate
    message_template.DisallowedFeature -> DisallowedPublishTemplate
    message_template.ExecutionFailed -> PublishTemplateExecutionFailed
    message_template.ExecutionTimedOut -> PublishTemplateExecutionTimedOut
  }
}

fn template_field_too_large(value: String) -> Bool {
  value
  |> bit_array.from_string
  |> bit_array.byte_size
  > message.max_message_bytes
}

fn apply_publish_parameters(
  draft: Draft,
  req: Request(BitArray),
) -> Result(Draft, PublishParameterError) {
  let title = param(req, ["x-title", "title", "t"])
  let body = case string.is_empty(draft.message) {
    True -> param(req, ["x-message", "message", "m"])
    False -> None
  }
  let priority = param(req, ["x-priority", "priority", "prio", "p"])
  apply_publish_parameter_values(draft, req, title:, body:, priority:)
}

fn apply_publish_parameter_values(
  draft: Draft,
  req: Request(BitArray),
  title title: Option(String),
  body body: Option(String),
  priority priority: Option(String),
) -> Result(Draft, PublishParameterError) {
  let tags = param(req, ["x-tags", "tags", "tag", "ta"])
  let markdown = param(req, ["x-markdown", "markdown", "md"])
  let cache = param(req, ["x-cache", "cache"])
  let actions = param(req, ["x-actions", "actions", "action"])
  let attach = param(req, ["x-attach", "attach", "a"])
  let filename = param(req, ["x-filename", "filename", "file", "f"])

  use priority <- result.try(case priority {
    Some(value) ->
      message.parse_priority(value)
      |> result.map_error(fn(_) { InvalidPublishPriority })
    None -> Ok(draft.priority)
  })
  use actions <- result.try(case actions {
    Some(value) ->
      action_parser.parse(value)
      |> result.map_error(fn(_) { InvalidPublishActions })
    None -> Ok(draft.actions)
  })
  let updated =
    message.Draft(
      ..draft,
      message: option.unwrap(body, draft.message),
      title: option.or(title, draft.title),
      priority:,
      tags: case tags {
        Some(value) -> split_csv(value)
        None -> draft.tags
      },
      markdown: option.map(markdown, parse_bool)
        |> option.unwrap(draft.markdown),
      icon: option.or(param(req, ["x-icon", "icon"]), draft.icon),
      click: option.or(param(req, ["x-click", "click"]), draft.click),
      actions:,
      attachment: case attach {
        None -> draft.attachment
        Some(url) ->
          Some(message.Attachment(
            name: option.unwrap(filename, attachment_name_from_url(url)),
            url:,
            mime_type: None,
            size: None,
            expires: None,
          ))
      },
      delay: option.or(
        param(req, ["x-delay", "delay", "x-at", "at", "x-in", "in"]),
        draft.delay,
      ),
      sequence_id: option.or(
        param(req, ["x-sequence-id", "sequence-id", "sid"]),
        draft.sequence_id,
      ),
      cache: option.map(cache, parse_bool) |> option.unwrap(draft.cache),
    )
  case updated.delay, updated.cache {
    Some(_), False -> Error(DelayedMessageWithoutCache)
    _, _ -> Ok(updated)
  }
}

fn attachment_name_from_url(url: String) -> String {
  let without_query =
    url
    |> string.split("?")
    |> list.first
    |> result.unwrap(url)
  let candidate =
    without_query
    |> string.split("/")
    |> list.last
    |> result.unwrap("attachment")
  case string.is_empty(candidate) {
    True -> "attachment"
    False -> candidate
  }
}

fn split_csv(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(value) { !string.is_empty(value) })
}

fn param(req: Request(body), aliases: List(String)) -> Option(String) {
  http_parameter.read(req, aliases)
}

fn truthy(value: Option(String)) -> Bool {
  option.map(value, parse_bool) |> option.unwrap(False)
}

fn parse_bool(value: String) -> Bool {
  list.contains(["1", "true", "yes", "on"], string.lowercase(value))
}

fn topic_or_error(
  topic_name: String,
) -> Result(topic.Topic, Response(BitArray)) {
  topic.parse(topic_name) |> result.map_error(fn(_) { page_not_found() })
}

fn with_authorization(
  req: Request(BitArray),
  topics: List(topic.Topic),
  operation: acl.Operation,
  runtime: Runtime,
  next: fn() -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case
    operation == acl.Write
    && http_auth.uses_session(req)
    && !http_auth.valid_csrf(req)
  {
    True -> ntfy_error(403, 40_303, "CSRF token required", ntfy_docs)
    False ->
      case http_auth.check(req, runtime.access, topics, operation, now()) {
        Ok(_) -> next()
        Error(http_auth.MalformedCredentials)
        | Error(http_auth.Unauthenticated) ->
          ntfy_error(401, 40_101, "unauthorized", auth_docs)
          |> response.set_header("www-authenticate", "Basic realm=\"notify\"")
        Error(http_auth.Forbidden) ->
          ntfy_error(403, 40_303, "forbidden", ntfy_docs)
        Error(http_auth.SetupRequired) ->
          ntfy_error(503, 50_301, "server setup is required", ntfy_docs)
        Error(http_auth.Unavailable) ->
          ntfy_error(503, 50_301, "authorization unavailable", ntfy_docs)
      }
  }
}

fn body_or_error(req: Request(BitArray)) -> Result(String, Response(BitArray)) {
  req.body
  |> bit_array.to_string
  |> result.map_error(fn(_) {
    ntfy_error(400, 40_007, "invalid UTF-8 request body", ntfy_docs)
  })
}

fn health(runtime: Runtime) -> Response(BitArray) {
  case runtime_ready(runtime) {
    True -> json_response(200, "{\"healthy\":true}")
    False -> json_response(503, "{\"healthy\":false}")
  }
}

fn liveness() -> Response(BitArray) {
  text_response("ok\n", 200, "text/plain; charset=utf-8")
}

fn readiness(runtime: Runtime) -> Response(BitArray) {
  case runtime_ready(runtime) {
    True -> text_response("ready\n", 200, "text/plain; charset=utf-8")
    False -> text_response("not ready\n", 503, "text/plain; charset=utf-8")
  }
}

fn runtime_ready(runtime: Runtime) -> Bool {
  let storage_ok = runtime.storage.health() |> result.is_ok
  let attachments_ok = case runtime.attachments {
    None -> True
    Some(store) -> store.health() |> result.is_ok
  }
  let deliveries_ok = case runtime.deliveries {
    None -> True
    Some(store) -> store.health() |> result.is_ok
  }
  let webpush_ok = case runtime.webpush {
    None -> True
    Some(configured) -> configured.store.health() |> result.is_ok
  }
  let audit_ok = case runtime.audit {
    None -> False
    Some(store) -> store.health() |> result.is_ok
  }
  storage_ok && attachments_ok && deliveries_ok && webpush_ok && audit_ok
}

fn metrics(runtime: Runtime) -> Response(BitArray) {
  let up = case runtime_ready(runtime) {
    True -> 1
    False -> 0
  }
  let statistics =
    runtime.storage.stats()
    |> result.unwrap(storage.Stats(messages: 0, scheduled: 0, events: 0))
  let delivery_statistics = case runtime.deliveries {
    None -> delivery.empty_stats()
    Some(store) -> store.stats() |> result.unwrap(delivery.empty_stats())
  }
  let audit_up = case runtime.audit {
    None -> 0
    Some(store) ->
      case store.health() |> result.is_ok {
        True -> 1
        False -> 0
      }
  }
  let body =
    "# HELP notify_up Whether all readiness dependencies are healthy.\n"
    <> "# TYPE notify_up gauge\nnotify_up "
    <> int.to_string(up)
    <> "\n# HELP notify_messages Cached messages.\n"
    <> "# TYPE notify_messages gauge\nnotify_messages "
    <> int.to_string(statistics.messages)
    <> "\n# HELP notify_scheduled_messages Messages waiting for their due time.\n"
    <> "# TYPE notify_scheduled_messages gauge\nnotify_scheduled_messages "
    <> int.to_string(statistics.scheduled)
    <> "\n# HELP notify_event_log_entries Durable event-log entries.\n"
    <> "# TYPE notify_event_log_entries gauge\nnotify_event_log_entries "
    <> int.to_string(statistics.events)
    <> "\n# HELP notify_audit_up Whether the append-only audit store is healthy.\n"
    <> "# TYPE notify_audit_up gauge\nnotify_audit_up "
    <> int.to_string(audit_up)
    <> "\n# HELP notify_delivery_jobs Durable delivery jobs by provider and state.\n"
    <> "# TYPE notify_delivery_jobs gauge\n"
    <> "notify_delivery_jobs{kind=\"webpush\",state=\"pending\"} "
    <> int.to_string(delivery_statistics.webpush_pending)
    <> "\nnotify_delivery_jobs{kind=\"webpush\",state=\"leased\"} "
    <> int.to_string(delivery_statistics.webpush_leased)
    <> "\nnotify_delivery_jobs{kind=\"webpush\",state=\"dead_letter\"} "
    <> int.to_string(delivery_statistics.webpush_dead_letter)
    <> "\nnotify_delivery_jobs{kind=\"mobile_relay\",state=\"pending\"} "
    <> int.to_string(delivery_statistics.mobile_relay_pending)
    <> "\nnotify_delivery_jobs{kind=\"mobile_relay\",state=\"leased\"} "
    <> int.to_string(delivery_statistics.mobile_relay_leased)
    <> "\nnotify_delivery_jobs{kind=\"mobile_relay\",state=\"dead_letter\"} "
    <> int.to_string(delivery_statistics.mobile_relay_dead_letter)
    <> "\n"
  text_response(body, 200, "text/plain; version=0.0.4; charset=utf-8")
}

fn version() -> Response(BitArray) {
  json_response(
    200,
    "{\"version\":\"0.1.0\",\"compatibility\":\"ntfy v2.27.0\"}",
  )
}

fn stats(runtime: Runtime) -> Response(BitArray) {
  case runtime.storage.stats() {
    Error(_) -> ntfy_error(503, 50_301, "storage unavailable", ntfy_docs)
    Ok(storage.Stats(messages:, ..)) ->
      json_response(
        200,
        json.object([
          #("messages", json.int(messages)),
          #("messages_rate", json.float(0.0)),
        ])
          |> json.to_string,
      )
  }
}

fn compatibility_config(runtime: Runtime) -> Response(BitArray) {
  let login_enabled = access.is_managed(runtime.access)
  let login_required = case access.default_access(runtime.access) {
    Ok(acl.Deny) -> True
    _ -> False
  }
  let #(webpush_enabled, webpush_public_key) = case runtime.webpush {
    None -> #(False, "")
    Some(configured) -> #(True, configured.public_key)
  }
  json_response(
    200,
    json.object([
      #("base_url", json.string(runtime.attachment_base_url)),
      #("app_root", json.string("/")),
      #("enable_login", json.bool(login_enabled)),
      #("require_login", json.bool(login_required)),
      #("enable_signup", json.bool(False)),
      #("enable_payments", json.bool(False)),
      #("enable_calls", json.bool(False)),
      #("enable_emails", json.bool(False)),
      #("enable_reset_password", json.bool(False)),
      #("enable_reservations", json.bool(False)),
      #("enable_web_push", json.bool(webpush_enabled)),
      #("billing_contact", json.string("")),
      #("web_push_public_key", json.string(webpush_public_key)),
      #("disallowed_topics", json.array([], json.string)),
      #("config_hash", json.string("notify-0.1.0")),
    ])
      |> json.to_string,
  )
}

fn invalid_topic() -> Response(BitArray) {
  ntfy_error(400, 40_009, "invalid request: topic invalid", "")
}

fn page_not_found() -> Response(BitArray) {
  ntfy_error(404, 40_401, "page not found", "")
}

fn ntfy_error(
  status: Int,
  code: Int,
  error: String,
  link: String,
) -> Response(BitArray) {
  let fields = [
    #("code", json.int(code)),
    #("http", json.int(status)),
    #("error", json.string(error)),
  ]
  let fields = case string.is_empty(link) {
    True -> fields
    False -> list.append(fields, [#("link", json.string(link))])
  }
  let body =
    json.object(fields)
    |> json.to_string
  json_response(status, body)
}

fn problem(status: Int, title: String, detail: String) -> Response(BitArray) {
  let body =
    json.object([
      #("type", json.string("about:blank")),
      #("title", json.string(title)),
      #("status", json.int(status)),
      #("detail", json.string(detail)),
    ])
    |> json.to_string
  text_response(body, status, "application/problem+json; charset=utf-8")
}

fn json_response(status: Int, body: String) -> Response(BitArray) {
  text_response(body, status, "application/json; charset=utf-8")
}

fn text_response(
  body: String,
  status: Int,
  content_type: String,
) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", content_type)
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_body(bit_array.from_string(body))
}

fn empty_response(status: Int) -> Response(BitArray) {
  text_response("", status, "text/plain; charset=utf-8")
}

fn cors_options_response() -> Response(BitArray) {
  response.new(200)
  |> response.set_body(<<>>)
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_header(
    "access-control-allow-methods",
    "GET, PUT, POST, PATCH, DELETE",
  )
  |> response.set_header("access-control-allow-headers", "*")
}

fn public_asset(name: String, content_type: String) -> Response(BitArray) {
  case read_public_asset(name) {
    Error(_) -> problem(404, "Asset not found", "The requested asset is absent")
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", content_type)
      |> response.set_header("x-content-type-options", "nosniff")
      |> response.set_header("referrer-policy", "no-referrer")
      |> response.set_header(
        "content-security-policy",
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
      )
      |> response.set_header("cache-control", case name {
        "sw.js" | "index.html" | "setup.html" -> "no-cache"
        _ -> "public, max-age=3600"
      })
      |> response.set_body(body)
  }
}

@external(erlang, "notify_ffi", "public_asset")
fn read_public_asset(name: String) -> Result(BitArray, Nil)

@external(erlang, "notify_ffi", "random_id")
fn random_id() -> String
