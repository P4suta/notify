import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import notify/access
import notify/attachment_store
import notify/audit
import notify/core/acl
import notify/delivery
import notify/http/audit_log
import notify/http/auth
import notify/http/cursor
import notify/identity
import notify/runtime.{type Runtime}
import notify/security/token

type LoginRequest {
  LoginRequest(username: String, password: String)
}

type UserRequest {
  UserRequest(username: String, password: String, role: acl.Role)
}

type PasswordRequest {
  PasswordRequest(password: String)
}

type TokenRequest {
  TokenRequest(username: String, label: String, expires: Option(Int))
}

type GrantRequest {
  GrantRequest(
    username: String,
    topic_pattern: String,
    permission: acl.Permission,
  )
}

type KeysetRequest {
  KeysetRequest(resource: String, limit: Int, after: Option(String))
}

type DeliveryFilter {
  AllDeliveryJobs
  WebPushDeliveryJobs
  MobileRelayDeliveryJobs
}

pub fn route(
  req: Request(BitArray),
  runtime: Runtime,
) -> Option(Response(BitArray)) {
  case req.method, request.path_segments(req) {
    Post, ["api", "v1", "session"] -> Some(login(req, runtime))
    Get, ["api", "v1", "session"] -> Some(current_session(req, runtime))
    Delete, ["api", "v1", "session"] -> Some(logout(req, runtime))
    Get, ["api", "v1", "users"] ->
      Some(with_admin(req, runtime, fn(_) { list_users(req, runtime) }))
    Post, ["api", "v1", "users"] ->
      Some(
        with_admin_mutation(req, runtime, audit.UserCreate, fn(_) {
          create_user(req, runtime)
        }),
      )
    Delete, ["api", "v1", "users", username] ->
      Some(
        with_admin_mutation(req, runtime, audit.UserDelete, fn(_) {
          delete_user(username, runtime)
        }),
      )
    Put, ["api", "v1", "users", username, "password"] ->
      Some(
        with_admin_mutation(req, runtime, audit.PasswordChange, fn(_) {
          change_password(req, username, runtime)
        }),
      )
    Get, ["api", "v1", "tokens"] ->
      Some(with_admin(req, runtime, fn(_) { list_tokens(req, runtime) }))
    Post, ["api", "v1", "tokens"] ->
      Some(
        with_admin_mutation(req, runtime, audit.TokenCreate, fn(_) {
          create_token(req, runtime)
        }),
      )
    Delete, ["api", "v1", "tokens", id] ->
      Some(
        with_admin_mutation(req, runtime, audit.TokenRevoke, fn(_) {
          revoke_token(id, runtime)
        }),
      )
    Get, ["api", "v1", "acl"] ->
      Some(with_admin(req, runtime, fn(_) { list_acl(req, runtime) }))
    Put, ["api", "v1", "acl"] | Post, ["api", "v1", "acl"] ->
      Some(
        with_admin_mutation(req, runtime, audit.AclChange, fn(_) {
          put_acl(req, runtime)
        }),
      )
    Delete, ["api", "v1", "acl"] ->
      Some(
        with_admin_mutation(req, runtime, audit.AclRevoke, fn(_) {
          delete_acl(req, runtime)
        }),
      )
    Get, ["api", "v1", "anonymous-access"] ->
      Some(with_admin(req, runtime, fn(_) { get_anonymous_access(runtime) }))
    Put, ["api", "v1", "anonymous-access"] ->
      Some(
        with_admin_mutation(req, runtime, audit.AnonymousAccessChange, fn(_) {
          put_anonymous_access(req, runtime)
        }),
      )
    Get, ["api", "v1", "system", "health"] ->
      Some(with_admin(req, runtime, fn(_) { system_health(runtime) }))
    Get, ["api", "v1", "delivery-jobs"] ->
      Some(with_admin(req, runtime, fn(_) { list_delivery_jobs(req, runtime) }))
    Post, ["api", "v1", "delivery-jobs", id, "retry"] ->
      Some(
        with_admin_mutation(req, runtime, audit.DeliveryRetry, fn(_) {
          retry_delivery_job(id, runtime)
        }),
      )
    Delete, ["api", "v1", "delivery-jobs", id] ->
      Some(
        with_admin_mutation(req, runtime, audit.DeliveryPurge, fn(_) {
          purge_delivery_job(id, runtime)
        }),
      )
    Get, ["api", "v1", "attachments"] ->
      Some(with_admin(req, runtime, fn(_) { list_attachments(req, runtime) }))
    Delete, ["api", "v1", "attachments", key] ->
      Some(
        with_admin_mutation(req, runtime, audit.AttachmentDelete, fn(_) {
          delete_attachment(key, runtime)
        }),
      )
    Get, ["api", "v1", "audit"] ->
      Some(with_admin(req, runtime, fn(_) { list_audit(req, runtime) }))
    _, _ -> None
  }
}

fn login(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use login <- parse_json_body(req, login_decoder())
  case
    audit_log.append(
      req,
      runtime,
      "anonymous",
      audit.SessionLogin,
      None,
      audit.Attempted,
      None,
    )
  {
    Error(_) -> audit_unavailable()
    Ok(_) -> {
      let runtime.Clock(now) = runtime.clock
      let reply = case
        access.setup_required(runtime.access),
        access.authenticate(
          runtime.access,
          access.Basic(login.username, login.password),
          now(),
        )
      {
        Ok(True), _ ->
          problem(
            503,
            "Setup required",
            "Complete the one-time server setup first",
          )
        _, Error(_) ->
          problem(401, "Authentication failed", "Invalid username or password")
        Error(_), _ ->
          problem(
            503,
            "Authentication unavailable",
            "Identity storage is unavailable",
          )
        Ok(False), Ok(principal) -> {
          let runtime.IdGenerator(next_id) = runtime.ids
          case
            access.create_token_for_username(
              runtime.access,
              fn() { "ses_" <> next_id() },
              login.username,
              "__web_session__",
              Some(now() + 43_200),
              now(),
              token.secure_entropy,
            )
          {
            Error(_) ->
              problem(
                503,
                "Session unavailable",
                "Could not persist the session",
              )
            Ok(#(_, raw)) -> {
              let #(username, role) = principal_name_role(principal)
              json_response(
                201,
                json.object([
                  #("username", json.string(username)),
                  #("role", json.string(role_string(role))),
                  #("csrf_token", json.string(csrf_token(raw))),
                  #("expires", json.int(now() + 43_200)),
                ]),
              )
              |> response.set_header(
                "set-cookie",
                "notify_session="
                  <> raw
                  <> "; Path=/; Max-Age=43200; Secure; HttpOnly; SameSite=Strict",
              )
            }
          }
        }
      }
      audited_result(
        reply,
        req,
        runtime,
        case reply.status == 201 {
          True -> login.username
          False -> "anonymous"
        },
        audit.SessionLogin,
        None,
      )
    }
  }
}

fn current_session(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(req, runtime.access, now()) {
    Ok(acl.Authenticated(username, role)) -> {
      let csrf = case auth.session_token(req) {
        Some(raw) -> csrf_token(raw)
        None -> ""
      }
      json_response(
        200,
        json.object([
          #("username", json.string(username)),
          #("role", json.string(role_string(role))),
          #("csrf_token", json.string(csrf)),
        ]),
      )
    }
    Ok(acl.Anonymous) | Error(auth.Unauthenticated) ->
      problem(401, "Authentication required", "Sign in to continue")
    Error(auth.SetupRequired) ->
      problem(503, "Setup required", "Complete server setup first")
    Error(_) ->
      problem(
        503,
        "Authentication unavailable",
        "Identity storage is unavailable",
      )
  }
}

fn logout(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case auth.session_token(req), auth.valid_csrf(req) {
    None, _ -> {
      let reply =
        problem(401, "Session required", "No web session cookie was sent")
      audited_result(
        reply,
        req,
        runtime,
        "anonymous",
        audit.SessionLogout,
        None,
      )
    }
    Some(_), False -> {
      let reply =
        problem(403, "CSRF check failed", "Send the session CSRF token")
      audited_result(
        reply,
        req,
        runtime,
        "anonymous",
        audit.SessionLogout,
        None,
      )
    }
    Some(raw), True -> {
      let runtime.Clock(now) = runtime.clock
      let actor = case auth.authenticate(req, runtime.access, now()) {
        Ok(acl.Authenticated(username, _)) -> username
        _ -> "anonymous"
      }
      case
        audit_log.append(
          req,
          runtime,
          actor,
          audit.SessionLogout,
          None,
          audit.Attempted,
          None,
        )
      {
        Error(_) -> audit_unavailable()
        Ok(_) -> {
          let reply = case access.revoke_raw_token(runtime.access, raw) {
            Error(_) ->
              problem(503, "Logout unavailable", "Could not revoke the session")
            Ok(_) ->
              response.new(204)
              |> response.set_header(
                "set-cookie",
                "notify_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict",
              )
              |> response.set_body(<<>>)
          }
          audited_result(reply, req, runtime, actor, audit.SessionLogout, None)
        }
      }
    }
  }
}

fn with_admin(
  req: Request(BitArray),
  runtime: Runtime,
  next: fn(String) -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(req, runtime.access, now()) {
    Ok(acl.Authenticated(username, acl.Admin)) -> next(username)
    Ok(_) | Error(auth.Unauthenticated) | Error(auth.MalformedCredentials) ->
      problem(
        401,
        "Administrator authentication required",
        "Sign in as an administrator",
      )
    Error(auth.SetupRequired) ->
      problem(503, "Setup required", "Complete server setup first")
    Error(_) ->
      problem(
        503,
        "Authorization unavailable",
        "Identity storage is unavailable",
      )
  }
}

fn with_admin_mutation(
  req: Request(BitArray),
  runtime: Runtime,
  action: audit.Action,
  next: fn(String) -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(req, runtime.access, now()) {
    Ok(acl.Authenticated(username, acl.Admin)) ->
      case auth.uses_session(req) && !auth.valid_csrf(req) {
        True -> {
          let reply =
            problem(403, "CSRF check failed", "Send the session CSRF token")
          audited_result(reply, req, runtime, username, action, Some(req.path))
        }
        False ->
          case
            audit_log.append(
              req,
              runtime,
              username,
              action,
              Some(req.path),
              audit.Attempted,
              None,
            )
          {
            Error(_) -> audit_unavailable()
            Ok(_) ->
              next(username)
              |> audited_result(req, runtime, username, action, Some(req.path))
          }
      }
    Ok(acl.Authenticated(username, _)) ->
      problem(
        401,
        "Administrator authentication required",
        "Sign in as an administrator",
      )
      |> audited_result(req, runtime, username, action, Some(req.path))
    Ok(acl.Anonymous)
    | Error(auth.Unauthenticated)
    | Error(auth.MalformedCredentials) ->
      problem(
        401,
        "Administrator authentication required",
        "Sign in as an administrator",
      )
      |> audited_result(req, runtime, "anonymous", action, Some(req.path))
    Error(auth.SetupRequired) ->
      problem(503, "Setup required", "Complete server setup first")
      |> audited_result(req, runtime, "anonymous", action, Some(req.path))
    Error(_) ->
      problem(
        503,
        "Authorization unavailable",
        "Identity storage is unavailable",
      )
      |> audited_result(req, runtime, "anonymous", action, Some(req.path))
  }
}

fn audited_result(
  reply: Response(BitArray),
  req: Request(BitArray),
  runtime: Runtime,
  actor: String,
  action: audit.Action,
  target: Option(String),
) -> Response(BitArray) {
  case
    audit_log.append(
      req,
      runtime,
      actor,
      action,
      target,
      audit_log.outcome_for_status(reply.status),
      Some(reply.status),
    )
  {
    Ok(_) -> reply
    Error(_) ->
      response.set_header(reply, "x-notify-audit-status", "incomplete")
  }
}

fn audit_unavailable() -> Response(BitArray) {
  problem(
    503,
    "Audit unavailable",
    "The security audit attempt could not be persisted",
  )
}

fn list_users(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case keyset_request(req, "users") {
    Error(_) -> invalid_page()
    Ok(page) -> {
      let KeysetRequest(after:, limit:, ..) = page
      case access.page_users(runtime.access, after, limit) {
        Error(_) -> problem(503, "Users unavailable", "Could not list users")
        Ok(users) ->
          stored_keyset_response(
            page,
            users,
            fn(user) { user.username },
            user_json,
          )
      }
    }
  }
}

fn create_user(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use new_user <- parse_json_body(req, user_decoder())
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  case
    access.add_user(
      runtime.access,
      "u_" <> next_id(),
      new_user.username,
      new_user.password,
      new_user.role,
      now(),
    )
  {
    Ok(user) -> json_response(201, user_json(user))
    Error(access.InvalidUsername) ->
      problem(400, "Invalid username", "Use 1-64 safe username characters")
    Error(access.PasswordError(_)) ->
      problem(400, "Invalid password", "Password must be 12-1024 characters")
    Error(access.IdentityError(identity.Conflict(_))) ->
      problem(409, "Username already exists", "Choose a different username")
    Error(_) ->
      problem(503, "User creation unavailable", "Could not persist the user")
  }
}

fn delete_user(username: String, runtime: Runtime) -> Response(BitArray) {
  case access.delete_user(runtime.access, username) {
    Ok(_) ->
      case runtime.webpush {
        None -> no_content()
        Some(configured) ->
          case configured.store.remove_user(username) {
            Ok(_) -> no_content()
            Error(_) ->
              problem(
                503,
                "Web Push cleanup unavailable",
                "The user was deleted, but their push subscriptions could not be removed",
              )
          }
      }
    Error(access.LastAdmin) ->
      problem(
        409,
        "Last administrator",
        "Create another administrator before deleting this user",
      )
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) ->
      problem(503, "User deletion unavailable", "Could not delete the user")
  }
}

fn change_password(
  req: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  use password <- parse_json_body(req, password_decoder())
  case access.change_password(runtime.access, username, password.password) {
    Ok(_) -> no_content()
    Error(access.PasswordError(_)) ->
      problem(400, "Invalid password", "Password must be 12-1024 characters")
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) ->
      problem(
        503,
        "Password update unavailable",
        "Could not update the password",
      )
  }
}

fn list_tokens(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case query(req, "username") {
    None -> problem(400, "Username required", "Pass ?username=<name>")
    Some(username) -> {
      case keyset_request(req, "tokens:" <> username) {
        Error(_) -> invalid_page()
        Ok(page) -> {
          let KeysetRequest(after:, limit:, ..) = page
          case access.page_tokens(runtime.access, username, after, limit) {
            Ok(tokens) ->
              stored_keyset_response(
                page,
                tokens,
                fn(token) { token.id },
                stored_token_json,
              )
            Error(access.IdentityError(identity.NotFound)) ->
              problem(404, "User not found", "No user has that username")
            Error(_) ->
              problem(503, "Tokens unavailable", "Could not list tokens")
          }
        }
      }
    }
  }
}

fn create_token(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use requested <- parse_json_body(req, token_decoder())
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  case
    access.create_token_for_username(
      runtime.access,
      fn() { "tok_" <> next_id() },
      requested.username,
      requested.label,
      requested.expires,
      now(),
      token.secure_entropy,
    )
  {
    Ok(#(stored, raw)) ->
      json_response(
        201,
        json.object([
          #("id", json.string(stored.id)),
          #("username", json.string(requested.username)),
          #("label", json.string(stored.label)),
          #("token", json.string(raw)),
          #("prefix", json.string(stored.prefix)),
          #("created_at", json.int(stored.created_at)),
          #("expires", json.nullable(stored.expires, json.int)),
          #("last_access", json.nullable(stored.last_access, json.int)),
        ]),
      )
    Error(access.InvalidTokenLabel) ->
      problem(
        400,
        "Invalid token label",
        "Token labels may be at most 64 characters",
      )
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) -> problem(503, "Token unavailable", "Could not create the token")
  }
}

fn revoke_token(id: String, runtime: Runtime) -> Response(BitArray) {
  case access.revoke_token(runtime.access, id) {
    Ok(_) -> no_content()
    Error(_) ->
      problem(503, "Token revocation unavailable", "Could not revoke the token")
  }
}

fn list_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  let username = query(req, "username")
  let resource = case username {
    None -> "acl:all"
    Some(username) -> "acl:user:" <> username
  }
  case keyset_request(req, resource) {
    Error(_) -> invalid_page()
    Ok(page) -> {
      let KeysetRequest(after:, limit:, ..) = page
      case grant_cursor(after) {
        Error(_) -> invalid_page()
        Ok(after) ->
          case access.page_grants(runtime.access, username, after, limit) {
            Ok(rules) ->
              stored_keyset_response(page, rules, rule_key, rule_json)
            Error(access.IdentityError(identity.InvalidPage)) -> invalid_page()
            Error(_) ->
              problem(503, "ACL unavailable", "Could not list access rules")
          }
      }
    }
  }
}

fn put_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use grant <- parse_json_body(req, grant_decoder())
  case
    access.grant(
      runtime.access,
      grant.username,
      grant.topic_pattern,
      grant.permission,
    )
  {
    Ok(rule) -> json_response(200, rule_json(rule))
    Error(access.InvalidUsername) | Error(access.InvalidTopicPattern) ->
      problem(
        400,
        "Invalid access rule",
        "Check the username and topic pattern",
      )
    Error(_) ->
      problem(503, "ACL unavailable", "Could not persist the access rule")
  }
}

fn delete_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use grant <- parse_json_body(req, grant_decoder())
  case
    access.revoke_grant(runtime.access, grant.username, grant.topic_pattern)
  {
    Ok(_) -> no_content()
    Error(_) ->
      problem(503, "ACL unavailable", "Could not revoke the access rule")
  }
}

fn get_anonymous_access(runtime: Runtime) -> Response(BitArray) {
  case access.default_access(runtime.access) {
    Ok(permission) ->
      json_response(
        200,
        json.object([
          #("permission", json.string(permission_string(permission))),
        ]),
      )
    Error(_) ->
      problem(503, "Policy unavailable", "Could not load the anonymous policy")
  }
}

fn put_anonymous_access(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use grant <- parse_json_body(req, permission_request_decoder())
  case access.set_default_access(runtime.access, grant.permission) {
    Ok(permission) ->
      json_response(
        200,
        json.object([
          #("permission", json.string(permission_string(permission))),
        ]),
      )
    Error(_) ->
      problem(
        503,
        "Policy unavailable",
        "Could not update the anonymous policy",
      )
  }
}

fn system_health(runtime: Runtime) -> Response(BitArray) {
  let storage_ok = runtime.storage.health() |> result.is_ok
  let attachment_ok = case runtime.attachments {
    None -> True
    Some(store) -> store.health() |> result.is_ok
  }
  let delivery_ok = case runtime.deliveries {
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
  let healthy =
    storage_ok && attachment_ok && delivery_ok && webpush_ok && audit_ok
  json_response(
    case healthy {
      True -> 200
      False -> 503
    },
    json.object([
      #("healthy", json.bool(healthy)),
      #(
        "storage",
        json.string(case storage_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "attachments",
        json.string(case attachment_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "delivery_outbox",
        json.string(case delivery_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "web_push",
        json.string(case webpush_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "audit",
        json.string(case audit_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "mobile_relay",
        json.string(case runtime.relay {
          None -> "disabled"
          Some(_) -> "configured"
        }),
      ),
      #("compatibility", json.string("ntfy v2.27.0")),
    ]),
  )
}

fn list_audit(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case runtime.audit {
    None ->
      problem(503, "Audit unavailable", "The security audit store is disabled")
    Some(store) ->
      case strict_page_limit(req), audit_cursor(req) {
        Error(_), _ | _, Error(_) ->
          problem(
            400,
            "Invalid audit page",
            "Use a limit from 1 to 100 and an unmodified audit cursor",
          )
        Ok(limit), Ok(after) ->
          case store.page(after, limit) {
            Error(audit.InvalidPage) ->
              problem(
                400,
                "Invalid audit page",
                "Use a limit from 1 to 100 and an unmodified audit cursor",
              )
            Error(_) ->
              problem(
                503,
                "Audit unavailable",
                "Could not read the security audit log",
              )
            Ok(page) -> {
              let next = case page.next {
                None -> None
                Some(audit.Cursor(sequence)) ->
                  Some(cursor.encode("audit", sequence))
              }
              page_response(page.items, next, audit_event_json)
            }
          }
      }
  }
}

fn audit_event_json(event: audit.Event) -> json.Json {
  json.object([
    #("sequence", json.int(event.sequence)),
    #("occurred_at", json.int(event.occurred_at)),
    #("actor", json.string(event.actor)),
    #("action", json.string(audit.action_name(event.action))),
    #("target", json.nullable(event.target, json.string)),
    #("outcome", json.string(audit.outcome_name(event.outcome))),
    #("status", json.nullable(event.status, json.int)),
    #("client_ip", json.string(event.client_ip)),
    #("request_id", json.string(event.request_id)),
  ])
}

fn strict_page_limit(req: Request(body)) -> Result(Int, Nil) {
  case query(req, "limit") {
    None -> Ok(50)
    Some(raw) ->
      case int.parse(raw) {
        Ok(limit) if limit >= 1 && limit <= 100 -> Ok(limit)
        _ -> Error(Nil)
      }
  }
}

fn audit_cursor(req: Request(body)) -> Result(Option(audit.Cursor), Nil) {
  case query(req, "cursor") {
    None -> Ok(None)
    Some(encoded) ->
      cursor.decode(encoded, "audit")
      |> result.map(fn(sequence) { Some(audit.Cursor(sequence)) })
      |> result.map_error(fn(_) { Nil })
  }
}

fn list_delivery_jobs(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case delivery_filter(req) {
    Error(_) ->
      problem(400, "Invalid delivery kind", "Use webpush or mobile_relay")
    Ok(filter) ->
      case keyset_request(req, delivery_resource(filter)) {
        Error(_) -> invalid_page()
        Ok(page) -> {
          let KeysetRequest(after:, limit:, ..) = page
          case runtime.deliveries {
            None ->
              keyset_response(
                page,
                [],
                fn(job: delivery.Job) { job.id },
                delivery_job_json,
              )
            Some(store) ->
              case store.page(delivery_filter_kind(filter), after, limit) {
                Ok(jobs) ->
                  delivery_keyset_response(
                    page,
                    jobs,
                    fn(job) { job.id },
                    delivery_summary_json,
                  )
                Error(delivery.InvalidPage) -> invalid_page()
                Error(_) ->
                  problem(
                    503,
                    "Delivery outbox unavailable",
                    "Could not list durable delivery jobs",
                  )
              }
          }
        }
      }
  }
}

fn delivery_filter(req: Request(body)) -> Result(DeliveryFilter, Nil) {
  case query(req, "kind") {
    None -> Ok(AllDeliveryJobs)
    Some("webpush") -> Ok(WebPushDeliveryJobs)
    Some("mobile_relay") | Some("relay") -> Ok(MobileRelayDeliveryJobs)
    Some(_) -> Error(Nil)
  }
}

fn delivery_resource(filter: DeliveryFilter) -> String {
  case filter {
    AllDeliveryJobs -> "delivery_jobs:all"
    WebPushDeliveryJobs -> "delivery_jobs:webpush"
    MobileRelayDeliveryJobs -> "delivery_jobs:mobile_relay"
  }
}

fn delivery_filter_kind(filter: DeliveryFilter) -> Option(delivery.Kind) {
  case filter {
    AllDeliveryJobs -> None
    WebPushDeliveryJobs -> Some(delivery.WebPush)
    MobileRelayDeliveryJobs -> Some(delivery.MobileRelay)
  }
}

fn delivery_job_json(job: delivery.Job) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("kind", json.string(delivery_kind_string(job.kind))),
    #("message_id", json.string(job.message_id)),
    #("topic_hash", json.string(job.topic_hash)),
    #("state", json.string(delivery_state_string(job.state))),
    #("attempts", json.int(job.attempts)),
    #("available_at", json.int(job.available_at)),
    #("lease_owner", json.nullable(job.lease_owner, json.string)),
    #("lease_until", json.nullable(job.lease_until, json.int)),
    #("last_error", json.nullable(job.last_error, json.string)),
  ])
}

fn delivery_summary_json(job: delivery.Summary) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("kind", json.string(delivery_kind_string(job.kind))),
    #("message_id", json.string(job.message_id)),
    #("topic_hash", json.string(job.topic_hash)),
    #("state", json.string(delivery_state_string(job.state))),
    #("attempts", json.int(job.attempts)),
    #("available_at", json.int(job.available_at)),
    #("lease_owner", json.nullable(job.lease_owner, json.string)),
    #("lease_until", json.nullable(job.lease_until, json.int)),
    #("last_error", json.nullable(job.last_error, json.string)),
  ])
}

fn retry_delivery_job(id: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.deliveries {
    None ->
      problem(404, "Delivery job not found", "The delivery outbox is disabled")
    Some(store) -> {
      let runtime.Clock(now) = runtime.clock
      case store.requeue(id, now()) {
        Ok(job) -> json_response(200, delivery_job_json(job))
        Error(delivery.NotFound) ->
          problem(404, "Delivery job not found", "No job has that ID")
        Error(delivery.Conflict) ->
          problem(
            409,
            "Delivery job is active",
            "Only dead-letter jobs can be retried manually",
          )
        Error(_) ->
          problem(
            503,
            "Delivery retry unavailable",
            "Could not requeue the delivery job",
          )
      }
    }
  }
}

fn purge_delivery_job(id: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.deliveries {
    None ->
      problem(404, "Delivery job not found", "The delivery outbox is disabled")
    Some(store) ->
      case store.purge(id) {
        Ok(_) -> no_content()
        Error(delivery.NotFound) ->
          problem(404, "Delivery job not found", "No job has that ID")
        Error(delivery.Conflict) ->
          problem(
            409,
            "Delivery job is active",
            "Only dead-letter jobs can be purged manually",
          )
        Error(_) ->
          problem(
            503,
            "Delivery purge unavailable",
            "Could not purge the delivery job",
          )
      }
  }
}

fn delivery_kind_string(kind: delivery.Kind) -> String {
  case kind {
    delivery.WebPush -> "webpush"
    delivery.MobileRelay -> "mobile_relay"
  }
}

fn delivery_state_string(state: delivery.State) -> String {
  case state {
    delivery.Pending -> "pending"
    delivery.Leased -> "leased"
    delivery.DeadLetter -> "dead_letter"
  }
}

fn list_attachments(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case keyset_request(req, "attachments") {
    Error(_) -> invalid_page()
    Ok(page) -> {
      let KeysetRequest(after:, limit:, ..) = page
      case runtime.attachments {
        None ->
          keyset_response(
            page,
            [],
            fn(item: attachment_store.Stored) { item.key },
            attachment_json,
          )
        Some(store) ->
          case store.page(after, limit) {
            Error(attachment_store.InvalidPage) -> invalid_page()
            Error(_) ->
              problem(
                503,
                "Attachments unavailable",
                "Could not list attachment metadata",
              )
            Ok(items) ->
              attachment_keyset_response(
                page,
                items,
                fn(item) { item.key },
                attachment_json,
              )
          }
      }
    }
  }
}

fn delete_attachment(key: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.attachments {
    None -> problem(404, "Attachment not found", "Attachments are disabled")
    Some(store) ->
      case store.head(key) {
        Error(attachment_store.NotFound) ->
          problem(404, "Attachment not found", "No attachment has that key")
        Error(_) ->
          problem(
            503,
            "Attachments unavailable",
            "Could not inspect the attachment",
          )
        Ok(_) ->
          case store.delete(key) {
            Ok(_) -> no_content()
            Error(_) ->
              problem(
                503,
                "Attachment deletion unavailable",
                "Could not delete the attachment",
              )
          }
      }
  }
}

fn attachment_json(stored: attachment_store.Stored) -> json.Json {
  json.object([
    #("key", json.string(stored.key)),
    #("size", json.int(stored.size)),
    #("expires", json.int(stored.expires)),
  ])
}

fn login_decoder() -> decode.Decoder(LoginRequest) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(LoginRequest(username:, password:))
}

fn user_decoder() -> decode.Decoder(UserRequest) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  use role <- decode.optional_field("role", acl.User, role_decoder())
  decode.success(UserRequest(username:, password:, role:))
}

fn password_decoder() -> decode.Decoder(PasswordRequest) {
  use password <- decode.field("password", decode.string)
  decode.success(PasswordRequest(password:))
}

fn token_decoder() -> decode.Decoder(TokenRequest) {
  use username <- decode.field("username", decode.string)
  use label <- decode.optional_field("label", "", decode.string)
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.int),
  )
  decode.success(TokenRequest(username:, label:, expires:))
}

fn grant_decoder() -> decode.Decoder(GrantRequest) {
  use username <- decode.field("username", decode.string)
  use topic_pattern <- decode.field("topic_pattern", decode.string)
  use permission <- decode.field("permission", permission_decoder())
  decode.success(GrantRequest(username:, topic_pattern:, permission:))
}

fn permission_request_decoder() -> decode.Decoder(GrantRequest) {
  use permission <- decode.field("permission", permission_decoder())
  decode.success(GrantRequest(username: "*", topic_pattern: "*", permission:))
}

fn role_decoder() -> decode.Decoder(acl.Role) {
  use value <- decode.then(decode.string)
  case string.lowercase(value) {
    "admin" -> decode.success(acl.Admin)
    "user" -> decode.success(acl.User)
    _ -> decode.failure(acl.User, expected: "user or admin")
  }
}

fn permission_decoder() -> decode.Decoder(acl.Permission) {
  use value <- decode.then(decode.string)
  case string.lowercase(value) {
    "deny" | "deny-all" | "none" -> decode.success(acl.Deny)
    "read" | "read-only" | "ro" -> decode.success(acl.ReadOnly)
    "write" | "write-only" | "wo" -> decode.success(acl.WriteOnly)
    "read-write" | "rw" -> decode.success(acl.ReadWrite)
    _ -> decode.failure(acl.Deny, expected: "access permission")
  }
}

fn user_json(user: identity.User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("username", json.string(user.username)),
    #("role", json.string(role_string(user.role))),
    #("created_at", json.int(user.created_at)),
  ])
}

fn stored_token_json(stored: identity.Token) -> json.Json {
  json.object([
    #("id", json.string(stored.id)),
    #("user_id", json.string(stored.user_id)),
    #("prefix", json.string(stored.prefix)),
    #("label", json.string(stored.label)),
    #("created_at", json.int(stored.created_at)),
    #("expires", json.nullable(stored.expires, json.int)),
    #("last_access", json.nullable(stored.last_access, json.int)),
  ])
}

fn rule_json(rule: acl.Rule) -> json.Json {
  json.object([
    #("username", json.string(rule.username)),
    #("topic_pattern", json.string(rule.topic_pattern)),
    #("permission", json.string(permission_string(rule.permission))),
  ])
}

fn rule_key(rule: acl.Rule) -> String {
  rule.username <> "\t" <> rule.topic_pattern
}

fn grant_cursor(
  after: Option(String),
) -> Result(Option(identity.GrantCursor), Nil) {
  case after {
    None -> Ok(None)
    Some(value) ->
      case string.split_once(value, "\t") {
        Error(_) -> Error(Nil)
        Ok(#(username, topic_pattern)) ->
          case
            username != ""
            && topic_pattern != ""
            && !string.contains(topic_pattern, "\t")
          {
            True -> Ok(Some(identity.GrantCursor(username:, topic_pattern:)))
            False -> Error(Nil)
          }
      }
  }
}

fn keyset_request(
  req: Request(body),
  resource: String,
) -> Result(KeysetRequest, Nil) {
  use limit <- result.try(strict_page_limit(req))
  use after <- result.try(case query(req, "cursor") {
    None -> Ok(None)
    Some(encoded) ->
      cursor.decode_key(encoded, resource)
      |> result.map(Some)
      |> result.map_error(fn(_) { Nil })
  })
  Ok(KeysetRequest(resource:, limit:, after:))
}

fn keyset_response(
  paging: KeysetRequest,
  items: List(a),
  key: fn(a) -> String,
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  let KeysetRequest(resource:, limit:, after:) = paging
  let sorted =
    list.sort(items, by: fn(left, right) {
      string.compare(key(left), key(right))
    })
  let selected = case after {
    None -> sorted
    Some(after) ->
      list.filter(sorted, fn(item) {
        string.compare(key(item), after) == order.Gt
      })
  }
  let items = list.take(selected, limit)
  let next_cursor = case list.length(selected) > limit {
    False -> None
    True ->
      items
      |> list.last
      |> result.map(fn(item) { cursor.encode_key(resource, key(item)) })
      |> option_from_result
  }
  page_response(items, next_cursor, encode)
}

fn stored_keyset_response(
  paging: KeysetRequest,
  stored: identity.Page(a),
  key: fn(a) -> String,
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  let KeysetRequest(resource:, ..) = paging
  let identity.Page(items:, has_more:) = stored
  let next_cursor = case has_more {
    False -> None
    True ->
      items
      |> list.last
      |> result.map(fn(item) { cursor.encode_key(resource, key(item)) })
      |> option_from_result
  }
  page_response(items, next_cursor, encode)
}

fn delivery_keyset_response(
  paging: KeysetRequest,
  stored: delivery.Page(a),
  key: fn(a) -> String,
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  let KeysetRequest(resource:, ..) = paging
  let delivery.Page(items:, has_more:) = stored
  let next_cursor = case has_more {
    False -> None
    True ->
      items
      |> list.last
      |> result.map(fn(item) { cursor.encode_key(resource, key(item)) })
      |> option_from_result
  }
  page_response(items, next_cursor, encode)
}

fn attachment_keyset_response(
  paging: KeysetRequest,
  stored: attachment_store.Page(a),
  key: fn(a) -> String,
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  let KeysetRequest(resource:, ..) = paging
  let attachment_store.Page(items:, has_more:) = stored
  let next_cursor = case has_more {
    False -> None
    True ->
      items
      |> list.last
      |> result.map(fn(item) { cursor.encode_key(resource, key(item)) })
      |> option_from_result
  }
  page_response(items, next_cursor, encode)
}

fn invalid_page() -> Response(BitArray) {
  problem(
    400,
    "Invalid page",
    "Use a limit from 1 to 100 and an unmodified cursor from this collection",
  )
}

fn page_response(
  items: List(a),
  next_cursor: Option(String),
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  json_response(
    200,
    json.object([
      #("items", json.array(items, encode)),
      #("next_cursor", json.nullable(next_cursor, json.string)),
    ]),
  )
}

fn query(req: Request(body), name: String) -> Option(String) {
  request.get_query(req)
  |> result.unwrap([])
  |> list.find_map(fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> option_from_result
}

fn parse_json_body(
  req: Request(BitArray),
  decoder: decode.Decoder(a),
  continue: fn(a) -> Response(BitArray),
) -> Response(BitArray) {
  case bit_array.to_string(req.body) {
    Error(_) -> problem(400, "Invalid JSON", "Request body is not UTF-8")
    Ok(body) ->
      case json.parse(body, decoder) {
        Error(_) ->
          problem(400, "Invalid JSON", "Request fields are missing or invalid")
        Ok(value) -> continue(value)
      }
  }
}

fn principal_name_role(principal: acl.Principal) -> #(String, acl.Role) {
  case principal {
    acl.Authenticated(username, role) -> #(username, role)
    acl.Anonymous -> #("", acl.User)
  }
}

fn csrf_token(raw: String) -> String {
  token.digest("csrf:" <> raw)
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.User -> "user"
    acl.Admin -> "admin"
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

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn json_response(status: Int, body: json.Json) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_body(body |> json.to_string |> bit_array.from_string)
}

fn problem(status: Int, title: String, detail: String) -> Response(BitArray) {
  json_response(
    status,
    json.object([
      #("type", json.string("about:blank")),
      #("title", json.string(title)),
      #("status", json.int(status)),
      #("detail", json.string(detail)),
    ]),
  )
  |> response.set_header(
    "content-type",
    "application/problem+json; charset=utf-8",
  )
}

fn no_content() -> Response(BitArray) {
  response.new(204)
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(<<>>)
}
