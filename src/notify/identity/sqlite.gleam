import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/core/acl
import notify/identity.{type Store, type Token, type User}
import notify/security/token as security_token
import sqlight.{type Connection}

pub type Started {
  Started(store: Store, setup_token: Option(String))
}

type Command {
  SetupRequired(Subject(Result(Bool, identity.Error)))
  IssueSetup(String, Int, Int, Subject(Result(Bool, identity.Error)))
  CompleteSetup(identity.Setup, Subject(Result(User, identity.Error)))
  UserByName(String, Subject(Result(User, identity.Error)))
  UserByTokenHash(String, Int, Subject(Result(User, identity.Error)))
  AuthorizationPolicy(
    String,
    Subject(Result(identity.AuthorizationPolicy, identity.Error)),
  )
  DefaultAccess(Subject(Result(acl.Permission, identity.Error)))
  SetDefaultAccess(
    acl.Permission,
    Subject(Result(acl.Permission, identity.Error)),
  )
  RulesFor(String, Subject(Result(List(acl.Rule), identity.Error)))
  AddUser(identity.NewUser, Subject(Result(User, identity.Error)))
  ListUsers(Subject(Result(List(User), identity.Error)))
  PageUsers(
    Option(String),
    Int,
    Subject(Result(identity.Page(User), identity.Error)),
  )
  DeleteUser(String, Subject(Result(Nil, identity.Error)))
  ChangePassword(String, String, Subject(Result(Nil, identity.Error)))
  AddToken(identity.NewToken, Subject(Result(Token, identity.Error)))
  ListTokens(String, Subject(Result(List(Token), identity.Error)))
  PageTokens(
    String,
    Option(String),
    Int,
    Subject(Result(identity.Page(Token), identity.Error)),
  )
  RevokeToken(String, Subject(Result(Nil, identity.Error)))
  RevokeTokenHash(String, Subject(Result(Nil, identity.Error)))
  PutGrant(acl.Rule, Subject(Result(acl.Rule, identity.Error)))
  DeleteGrant(String, String, Subject(Result(Nil, identity.Error)))
  ListGrants(Option(String), Subject(Result(List(acl.Rule), identity.Error)))
  PageGrants(
    Option(String),
    Option(identity.GrantCursor),
    Int,
    Subject(Result(identity.Page(acl.Rule), identity.Error)),
  )
}

const setup_lifetime_seconds = 900

const migration = "
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS auth_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  setup_complete INTEGER NOT NULL DEFAULT 0,
  anonymous_read INTEGER NOT NULL DEFAULT 0,
  anonymous_write INTEGER NOT NULL DEFAULT 0
);
INSERT OR IGNORE INTO auth_state(id) VALUES (1);

CREATE TABLE IF NOT EXISTS setup_challenge (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  token_hash TEXT NOT NULL,
  expires INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL CHECK (role IN ('user', 'admin')),
  password_hash TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS access_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  token_hash TEXT NOT NULL UNIQUE,
  token_prefix TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires INTEGER,
  FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS access_tokens_user_id ON access_tokens(user_id);
CREATE INDEX IF NOT EXISTS access_tokens_user_id_id ON access_tokens(user_id, id);

CREATE TABLE IF NOT EXISTS access_token_activity (
  token_id TEXT PRIMARY KEY,
  last_access INTEGER NOT NULL,
  FOREIGN KEY(token_id) REFERENCES access_tokens(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS acl_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL,
  topic_pattern TEXT NOT NULL,
  readable INTEGER NOT NULL,
  writable INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  UNIQUE(username, topic_pattern)
);
CREATE INDEX IF NOT EXISTS acl_rules_username ON acl_rules(username);

INSERT OR IGNORE INTO schema_migrations(version) VALUES (2);
"

pub fn start(
  path: String,
  now: fn() -> Int,
  setup_entropy: fn() -> String,
) -> Result(Started, identity.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
    Ok(_) -> {
      use store <- result.try(start_actor(connection))
      use required <- result.try(store.setup_required())
      case required {
        False -> Ok(Started(store:, setup_token: None))
        True -> {
          use issued <- result.try(
            security_token.issue_setup(setup_entropy)
            |> result.map_error(fn(_) {
              identity.Unavailable("secure setup token generation failed")
            }),
          )
          let issued_at = now()
          use installed <- result.try(store.issue_setup(
            issued.hash,
            issued_at + setup_lifetime_seconds,
            issued_at,
          ))
          Ok(
            Started(store:, setup_token: case installed {
              True -> Some(issued.value)
              False -> None
            }),
          )
        }
      }
    }
  }
}

/// Opens the identity store without creating or rotating a setup challenge.
/// This is used by local administrative commands after initial setup.
pub fn open_store(path: String) -> Result(Store, identity.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
    Ok(_) -> start_actor(connection)
  }
}

/// Creates or upgrades only the identity schema and closes the connection.
/// This is intended for offline, transactional maintenance commands.
pub fn prepare(path: String) -> Result(Nil, identity.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  let migrated = migrate(connection)
  let _ = sqlight.close(connection)
  migrated
}

fn start_actor(connection: Connection) -> Result(Store, identity.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      identity.Unavailable("identity actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    identity.Store(
      setup_required: fn() { process.call(subject, 10_000, SetupRequired) },
      issue_setup: fn(hash, expires, now) {
        process.call(subject, 10_000, fn(reply) {
          IssueSetup(hash, expires, now, reply)
        })
      },
      complete_setup: fn(setup) {
        process.call(subject, 30_000, fn(reply) { CompleteSetup(setup, reply) })
      },
      user_by_name: fn(username) {
        process.call(subject, 10_000, fn(reply) { UserByName(username, reply) })
      },
      user_by_token_hash: fn(hash, now) {
        process.call(subject, 10_000, fn(reply) {
          UserByTokenHash(hash, now, reply)
        })
      },
      authorization_policy: fn(username) {
        process.call(subject, 10_000, fn(reply) {
          AuthorizationPolicy(username, reply)
        })
      },
      default_access: fn() { process.call(subject, 10_000, DefaultAccess) },
      set_default_access: fn(permission) {
        process.call(subject, 10_000, fn(reply) {
          SetDefaultAccess(permission, reply)
        })
      },
      rules_for: fn(username) {
        process.call(subject, 10_000, fn(reply) { RulesFor(username, reply) })
      },
      add_user: fn(user) {
        process.call(subject, 30_000, fn(reply) { AddUser(user, reply) })
      },
      list_users: fn() { process.call(subject, 10_000, ListUsers) },
      page_users: fn(after, limit) {
        process.call(subject, 10_000, fn(reply) {
          PageUsers(after, limit, reply)
        })
      },
      delete_user: fn(username) {
        process.call(subject, 10_000, fn(reply) { DeleteUser(username, reply) })
      },
      change_password: fn(username, hash) {
        process.call(subject, 10_000, fn(reply) {
          ChangePassword(username, hash, reply)
        })
      },
      add_token: fn(token) {
        process.call(subject, 10_000, fn(reply) { AddToken(token, reply) })
      },
      list_tokens: fn(user_id) {
        process.call(subject, 10_000, fn(reply) { ListTokens(user_id, reply) })
      },
      page_tokens: fn(user_id, after, limit) {
        process.call(subject, 10_000, fn(reply) {
          PageTokens(user_id, after, limit, reply)
        })
      },
      revoke_token: fn(id) {
        process.call(subject, 10_000, fn(reply) { RevokeToken(id, reply) })
      },
      revoke_token_hash: fn(hash) {
        process.call(subject, 10_000, fn(reply) { RevokeTokenHash(hash, reply) })
      },
      put_grant: fn(rule) {
        process.call(subject, 10_000, fn(reply) { PutGrant(rule, reply) })
      },
      delete_grant: fn(username, pattern) {
        process.call(subject, 10_000, fn(reply) {
          DeleteGrant(username, pattern, reply)
        })
      },
      list_grants: fn(username) {
        process.call(subject, 10_000, fn(reply) { ListGrants(username, reply) })
      },
      page_grants: fn(username, after, limit) {
        process.call(subject, 10_000, fn(reply) {
          PageGrants(username, after, limit, reply)
        })
      },
    ),
  )
}

fn handle(
  connection: Connection,
  command: Command,
) -> actor.Next(Connection, Command) {
  case command {
    SetupRequired(reply) -> respond(connection, reply, setup_required)
    IssueSetup(hash, expires, now, reply) ->
      respond3(connection, reply, hash, expires, now, issue_setup)
    CompleteSetup(setup, reply) ->
      respond1(connection, reply, setup, complete_setup)
    UserByName(username, reply) ->
      respond1(connection, reply, username, user_by_name)
    UserByTokenHash(hash, now, reply) ->
      respond2(connection, reply, hash, now, user_by_token_hash)
    AuthorizationPolicy(username, reply) ->
      respond1(connection, reply, username, authorization_policy)
    DefaultAccess(reply) -> respond(connection, reply, default_access)
    SetDefaultAccess(permission, reply) ->
      respond1(connection, reply, permission, set_default_access)
    RulesFor(username, reply) ->
      respond1(connection, reply, username, rules_for)
    AddUser(user, reply) -> respond1(connection, reply, user, add_user)
    ListUsers(reply) -> respond(connection, reply, list_users)
    PageUsers(after, limit, reply) ->
      respond2(connection, reply, after, limit, page_users)
    DeleteUser(username, reply) ->
      respond1(connection, reply, username, delete_user)
    ChangePassword(username, hash, reply) ->
      respond2(connection, reply, username, hash, change_password)
    AddToken(token, reply) -> respond1(connection, reply, token, add_token)
    ListTokens(user_id, reply) ->
      respond1(connection, reply, user_id, list_tokens)
    PageTokens(user_id, after, limit, reply) ->
      respond3(connection, reply, user_id, after, limit, page_tokens)
    RevokeToken(id, reply) -> respond1(connection, reply, id, revoke_token)
    RevokeTokenHash(hash, reply) ->
      respond1(connection, reply, hash, revoke_token_hash)
    PutGrant(rule, reply) -> respond1(connection, reply, rule, put_grant)
    DeleteGrant(username, pattern, reply) ->
      respond2(connection, reply, username, pattern, delete_grant)
    ListGrants(username, reply) ->
      respond1(connection, reply, username, list_grants)
    PageGrants(username, after, limit, reply) ->
      respond3(connection, reply, username, after, limit, page_grants)
  }
}

fn respond(
  connection: Connection,
  reply: Subject(a),
  operation: fn(Connection) -> a,
) -> actor.Next(Connection, Command) {
  process.send(reply, operation(connection))
  actor.continue(connection)
}

fn respond1(
  connection: Connection,
  reply: Subject(a),
  value: b,
  operation: fn(Connection, b) -> a,
) -> actor.Next(Connection, Command) {
  process.send(reply, operation(connection, value))
  actor.continue(connection)
}

fn respond2(
  connection: Connection,
  reply: Subject(a),
  first: b,
  second: c,
  operation: fn(Connection, b, c) -> a,
) -> actor.Next(Connection, Command) {
  process.send(reply, operation(connection, first, second))
  actor.continue(connection)
}

fn respond3(
  connection: Connection,
  reply: Subject(a),
  first: b,
  second: c,
  third: d,
  operation: fn(Connection, b, c, d) -> a,
) -> actor.Next(Connection, Command) {
  process.send(reply, operation(connection, first, second, third))
  actor.continue(connection)
}

fn migrate(connection: Connection) -> Result(Nil, identity.Error) {
  sqlight.exec(migration, connection) |> result.map_error(map_error)
}

fn setup_required(connection: Connection) -> Result(Bool, identity.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT setup_complete FROM auth_state WHERE id = 1",
      on: connection,
      with: [],
      expecting: {
        use complete <- decode.field(0, decode.int)
        decode.success(complete)
      },
    )
    |> result.map_error(map_error),
  )
  case rows {
    [complete] -> Ok(complete == 0)
    _ -> Error(identity.Corrupt("auth_state row is missing"))
  }
}

fn issue_setup(
  connection: Connection,
  hash: String,
  expires: Int,
  now: Int,
) -> Result(Bool, identity.Error) {
  in_transaction(connection, fn() {
    use required <- result.try(setup_required(connection))
    case required {
      False -> Error(identity.SetupAlreadyComplete)
      True -> {
        use active <- result.try(
          sqlight.query(
            "SELECT 1 FROM setup_challenge WHERE id = 1 AND expires > ?",
            on: connection,
            with: [sqlight.int(now)],
            expecting: {
              use found <- decode.field(0, decode.int)
              decode.success(found)
            },
          )
          |> result.map_error(map_error),
        )
        case active {
          [_] -> Ok(False)
          [] ->
            sqlight.query(
              "INSERT INTO setup_challenge(id, token_hash, expires) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET token_hash = excluded.token_hash, expires = excluded.expires",
              on: connection,
              with: [sqlight.text(hash), sqlight.int(expires)],
              expecting: decode.dynamic,
            )
            |> result.map(fn(_) { True })
            |> result.map_error(map_error)
          _ -> Error(identity.Corrupt("multiple setup challenges"))
        }
      }
    }
  })
}

fn complete_setup(
  connection: Connection,
  setup: identity.Setup,
) -> Result(User, identity.Error) {
  in_transaction(connection, fn() {
    use required <- result.try(setup_required(connection))
    case required {
      False -> Error(identity.SetupAlreadyComplete)
      True -> {
        use challenge <- result.try(
          sqlight.query(
            "SELECT 1 FROM setup_challenge WHERE id = 1 AND token_hash = ? AND expires >= ?",
            on: connection,
            with: [sqlight.text(setup.token_hash), sqlight.int(setup.now)],
            expecting: {
              use found <- decode.field(0, decode.int)
              decode.success(found)
            },
          )
          |> result.map_error(map_error),
        )
        case challenge {
          [] -> Error(identity.InvalidSetupToken)
          [_] -> {
            let user =
              identity.User(
                id: setup.user_id,
                username: setup.username,
                role: acl.Admin,
                password_hash: setup.password_hash,
                created_at: setup.now,
              )
            use _ <- result.try(insert_user(connection, user))
            let #(read, write) =
              identity.permission_bits(setup.anonymous_access)
            use _ <- result.try(
              sqlight.query(
                "UPDATE auth_state SET setup_complete = 1, anonymous_read = ?, anonymous_write = ? WHERE id = 1 AND setup_complete = 0",
                on: connection,
                with: [sqlight.bool(read), sqlight.bool(write)],
                expecting: decode.dynamic,
              )
              |> result.map_error(map_error),
            )
            use _ <- result.try(
              sqlight.exec("DELETE FROM setup_challenge", connection)
              |> result.map_error(map_error),
            )
            Ok(user)
          }
          _ -> Error(identity.Corrupt("multiple setup challenges"))
        }
      }
    }
  })
}

fn user_by_name(
  connection: Connection,
  username: String,
) -> Result(User, identity.Error) {
  query_one_user(
    connection,
    "SELECT id, username, role, password_hash, created_at FROM users WHERE username = ?",
    [sqlight.text(username)],
  )
}

fn user_by_token_hash(
  connection: Connection,
  hash: String,
  now: Int,
) -> Result(User, identity.Error) {
  in_transaction(connection, fn() {
    use user <- result.try(
      query_one_user(
        connection,
        "SELECT u.id, u.username, u.role, u.password_hash, u.created_at FROM users u JOIN access_tokens t ON t.user_id = u.id WHERE t.token_hash = ? AND (t.expires IS NULL OR t.expires >= ?)",
        [sqlight.text(hash), sqlight.int(now)],
      ),
    )
    use _ <- result.try(
      sqlight.query(
        "INSERT INTO access_token_activity(token_id, last_access) SELECT id, ? FROM access_tokens WHERE token_hash = ? AND (expires IS NULL OR expires >= ?) ON CONFLICT(token_id) DO UPDATE SET last_access = MAX(access_token_activity.last_access, excluded.last_access)",
        on: connection,
        with: [sqlight.int(now), sqlight.text(hash), sqlight.int(now)],
        expecting: decode.dynamic,
      )
      |> result.map_error(map_error),
    )
    Ok(user)
  })
}

type AuthorizationRow {
  AuthorizationRow(
    setup_required: Bool,
    default_access: acl.Permission,
    rule: Option(acl.Rule),
  )
}

fn authorization_policy(
  connection: Connection,
  username: String,
) -> Result(identity.AuthorizationPolicy, identity.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT NOT state.setup_complete, state.anonymous_read, state.anonymous_write, 0, '', '', 0, 0 FROM auth_state AS state WHERE state.id = 1 UNION ALL SELECT NOT state.setup_complete, state.anonymous_read, state.anonymous_write, 1, rule.username, rule.topic_pattern, rule.readable, rule.writable FROM auth_state AS state JOIN acl_rules AS rule ON rule.username = ? OR rule.username = '*' WHERE state.id = 1",
      on: connection,
      with: [sqlight.text(username)],
      expecting: authorization_row_decoder(),
    )
    |> result.map_error(map_error),
  )
  case rows {
    [] -> Error(identity.Corrupt("auth_state row is missing"))
    [first, ..rows] ->
      Ok(identity.AuthorizationPolicy(
        setup_required: first.setup_required,
        default_access: first.default_access,
        rules: [first, ..rows]
          |> list.filter_map(fn(row) {
            case row.rule {
              Some(rule) -> Ok(rule)
              None -> Error(Nil)
            }
          }),
      ))
  }
}

fn default_access(
  connection: Connection,
) -> Result(acl.Permission, identity.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT anonymous_read, anonymous_write FROM auth_state WHERE id = 1",
      on: connection,
      with: [],
      expecting: {
        use read <- decode.field(0, decode.int)
        use write <- decode.field(1, decode.int)
        decode.success(identity.permission_from_bits(read != 0, write != 0))
      },
    )
    |> result.map_error(map_error),
  )
  case rows {
    [permission] -> Ok(permission)
    _ -> Error(identity.Corrupt("auth_state row is missing"))
  }
}

fn set_default_access(
  connection: Connection,
  permission: acl.Permission,
) -> Result(acl.Permission, identity.Error) {
  let #(read, write) = identity.permission_bits(permission)
  sqlight.query(
    "UPDATE auth_state SET anonymous_read = ?, anonymous_write = ? WHERE id = 1 AND setup_complete = 1",
    on: connection,
    with: [sqlight.bool(read), sqlight.bool(write)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { permission })
  |> result.map_error(map_error)
}

fn rules_for(
  connection: Connection,
  username: String,
) -> Result(List(acl.Rule), identity.Error) {
  query_rules(
    connection,
    "SELECT username, topic_pattern, readable, writable FROM acl_rules WHERE username = ? OR username = '*'",
    [sqlight.text(username)],
  )
}

fn add_user(
  connection: Connection,
  new_user: identity.NewUser,
) -> Result(User, identity.Error) {
  let identity.NewUser(id:, username:, role:, password_hash:, created_at:) =
    new_user
  let user = identity.User(id:, username:, role:, password_hash:, created_at:)
  use _ <- result.try(insert_user(connection, user))
  Ok(user)
}

fn insert_user(
  connection: Connection,
  user: User,
) -> Result(Nil, identity.Error) {
  sqlight.query(
    "INSERT INTO users(id, username, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?)",
    on: connection,
    with: [
      sqlight.text(user.id),
      sqlight.text(user.username),
      sqlight.text(role_string(user.role)),
      sqlight.text(user.password_hash),
      sqlight.int(user.created_at),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn list_users(connection: Connection) -> Result(List(User), identity.Error) {
  sqlight.query(
    "SELECT id, username, role, password_hash, created_at FROM users ORDER BY username ASC",
    on: connection,
    with: [],
    expecting: user_decoder(),
  )
  |> result.map_error(map_error)
}

fn page_users(
  connection: Connection,
  after: Option(String),
  limit: Int,
) -> Result(identity.Page(User), identity.Error) {
  use _ <- result.try(valid_page_limit(limit))
  let rows = case after {
    None ->
      sqlight.query(
        "SELECT id, username, role, password_hash, created_at FROM users ORDER BY username ASC LIMIT ?",
        on: connection,
        with: [sqlight.int(limit + 1)],
        expecting: user_decoder(),
      )
    Some(after) ->
      sqlight.query(
        "SELECT id, username, role, password_hash, created_at FROM users WHERE username > ? ORDER BY username ASC LIMIT ?",
        on: connection,
        with: [sqlight.text(after), sqlight.int(limit + 1)],
        expecting: user_decoder(),
      )
  }
  rows
  |> result.map(fn(rows) { bounded_page(rows, limit) })
  |> result.map_error(map_error)
}

fn delete_user(
  connection: Connection,
  username: String,
) -> Result(Nil, identity.Error) {
  in_transaction(connection, fn() {
    use _ <- result.try(
      sqlight.query(
        "DELETE FROM acl_rules WHERE username = ?",
        on: connection,
        with: [sqlight.text(username)],
        expecting: decode.dynamic,
      )
      |> result.map_error(map_error),
    )
    sqlight.query(
      "DELETE FROM users WHERE username = ?",
      on: connection,
      with: [sqlight.text(username)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(map_error)
  })
}

fn change_password(
  connection: Connection,
  username: String,
  hash: String,
) -> Result(Nil, identity.Error) {
  sqlight.query(
    "UPDATE users SET password_hash = ? WHERE username = ?",
    on: connection,
    with: [sqlight.text(hash), sqlight.text(username)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn add_token(
  connection: Connection,
  new_token: identity.NewToken,
) -> Result(Token, identity.Error) {
  let identity.NewToken(
    id:,
    user_id:,
    token_hash:,
    prefix:,
    label:,
    created_at:,
    expires:,
  ) = new_token
  use _ <- result.try(
    sqlight.query(
      "INSERT INTO access_tokens(id, user_id, token_hash, token_prefix, label, created_at, expires) VALUES (?, ?, ?, ?, ?, ?, ?)",
      on: connection,
      with: [
        sqlight.text(id),
        sqlight.text(user_id),
        sqlight.text(token_hash),
        sqlight.text(prefix),
        sqlight.text(label),
        sqlight.int(created_at),
        sqlight.nullable(sqlight.int, expires),
      ],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  Ok(identity.Token(
    id:,
    user_id:,
    prefix:,
    label:,
    created_at:,
    expires:,
    last_access: None,
  ))
}

fn list_tokens(
  connection: Connection,
  user_id: String,
) -> Result(List(Token), identity.Error) {
  sqlight.query(
    "SELECT t.id, t.user_id, t.token_prefix, t.label, t.created_at, t.expires, a.last_access FROM access_tokens t LEFT JOIN access_token_activity a ON a.token_id = t.id WHERE t.user_id = ? ORDER BY t.created_at DESC, t.id ASC",
    on: connection,
    with: [sqlight.text(user_id)],
    expecting: token_decoder(),
  )
  |> result.map_error(map_error)
}

fn page_tokens(
  connection: Connection,
  user_id: String,
  after: Option(String),
  limit: Int,
) -> Result(identity.Page(Token), identity.Error) {
  use _ <- result.try(valid_page_limit(limit))
  let rows = case after {
    None ->
      sqlight.query(
        "SELECT t.id, t.user_id, t.token_prefix, t.label, t.created_at, t.expires, a.last_access FROM access_tokens t LEFT JOIN access_token_activity a ON a.token_id = t.id WHERE t.user_id = ? ORDER BY t.id ASC LIMIT ?",
        on: connection,
        with: [sqlight.text(user_id), sqlight.int(limit + 1)],
        expecting: token_decoder(),
      )
    Some(after) ->
      sqlight.query(
        "SELECT t.id, t.user_id, t.token_prefix, t.label, t.created_at, t.expires, a.last_access FROM access_tokens t LEFT JOIN access_token_activity a ON a.token_id = t.id WHERE t.user_id = ? AND t.id > ? ORDER BY t.id ASC LIMIT ?",
        on: connection,
        with: [
          sqlight.text(user_id),
          sqlight.text(after),
          sqlight.int(limit + 1),
        ],
        expecting: token_decoder(),
      )
  }
  rows
  |> result.map(fn(rows) { bounded_page(rows, limit) })
  |> result.map_error(map_error)
}

fn revoke_token(
  connection: Connection,
  id: String,
) -> Result(Nil, identity.Error) {
  sqlight.query(
    "DELETE FROM access_tokens WHERE id = ?",
    on: connection,
    with: [sqlight.text(id)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn revoke_token_hash(
  connection: Connection,
  hash: String,
) -> Result(Nil, identity.Error) {
  sqlight.query(
    "DELETE FROM access_tokens WHERE token_hash = ?",
    on: connection,
    with: [sqlight.text(hash)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn put_grant(
  connection: Connection,
  rule: acl.Rule,
) -> Result(acl.Rule, identity.Error) {
  let acl.Rule(username:, topic_pattern:, permission:) = rule
  let #(read, write) = identity.permission_bits(permission)
  use _ <- result.try(
    sqlight.query(
      "INSERT INTO acl_rules(username, topic_pattern, readable, writable) VALUES (?, ?, ?, ?) ON CONFLICT(username, topic_pattern) DO UPDATE SET readable = excluded.readable, writable = excluded.writable",
      on: connection,
      with: [
        sqlight.text(username),
        sqlight.text(topic_pattern),
        sqlight.bool(read),
        sqlight.bool(write),
      ],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  Ok(rule)
}

fn delete_grant(
  connection: Connection,
  username: String,
  pattern: String,
) -> Result(Nil, identity.Error) {
  sqlight.query(
    "DELETE FROM acl_rules WHERE username = ? AND topic_pattern = ?",
    on: connection,
    with: [sqlight.text(username), sqlight.text(pattern)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn list_grants(
  connection: Connection,
  username: Option(String),
) -> Result(List(acl.Rule), identity.Error) {
  case username {
    None ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM acl_rules ORDER BY username, topic_pattern",
        [],
      )
    Some(username) ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM acl_rules WHERE username = ? ORDER BY topic_pattern",
        [sqlight.text(username)],
      )
  }
}

fn page_grants(
  connection: Connection,
  username: Option(String),
  after: Option(identity.GrantCursor),
  limit: Int,
) -> Result(identity.Page(acl.Rule), identity.Error) {
  use _ <- result.try(valid_page_limit(limit))
  let rows = case username, after {
    None, None ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM acl_rules ORDER BY username, topic_pattern LIMIT ?",
        [sqlight.int(limit + 1)],
      )
    None, Some(identity.GrantCursor(after_user, after_pattern)) ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM acl_rules WHERE username > ? OR (username = ? AND topic_pattern > ?) ORDER BY username, topic_pattern LIMIT ?",
        [
          sqlight.text(after_user),
          sqlight.text(after_user),
          sqlight.text(after_pattern),
          sqlight.int(limit + 1),
        ],
      )
    Some(username), None ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM acl_rules WHERE username = ? ORDER BY topic_pattern LIMIT ?",
        [sqlight.text(username), sqlight.int(limit + 1)],
      )
    Some(username), Some(identity.GrantCursor(after_user, after_pattern)) ->
      case username == after_user {
        False -> Error(identity.InvalidPage)
        True ->
          query_rules(
            connection,
            "SELECT username, topic_pattern, readable, writable FROM acl_rules WHERE username = ? AND topic_pattern > ? ORDER BY topic_pattern LIMIT ?",
            [
              sqlight.text(username),
              sqlight.text(after_pattern),
              sqlight.int(limit + 1),
            ],
          )
      }
  }
  rows |> result.map(fn(rows) { bounded_page(rows, limit) })
}

fn valid_page_limit(limit: Int) -> Result(Nil, identity.Error) {
  case limit >= 1 && limit <= 100 {
    True -> Ok(Nil)
    False -> Error(identity.InvalidPage)
  }
}

fn bounded_page(rows: List(a), limit: Int) -> identity.Page(a) {
  identity.Page(
    items: list.take(rows, limit),
    has_more: list.length(rows) > limit,
  )
}

fn query_rules(
  connection: Connection,
  statement: String,
  parameters: List(sqlight.Value),
) -> Result(List(acl.Rule), identity.Error) {
  sqlight.query(
    statement,
    on: connection,
    with: parameters,
    expecting: rule_decoder(),
  )
  |> result.map_error(map_error)
}

fn query_one_user(
  connection: Connection,
  statement: String,
  parameters: List(sqlight.Value),
) -> Result(User, identity.Error) {
  use users <- result.try(
    sqlight.query(
      statement,
      on: connection,
      with: parameters,
      expecting: user_decoder(),
    )
    |> result.map_error(map_error),
  )
  case users {
    [user] -> Ok(user)
    [] -> Error(identity.NotFound)
    _ -> Error(identity.Corrupt("identity lookup returned multiple users"))
  }
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.string)
  use username <- decode.field(1, decode.string)
  use role <- decode.field(2, decode.string)
  use password_hash <- decode.field(3, decode.string)
  use created_at <- decode.field(4, decode.int)
  decode.success(identity.User(
    id:,
    username:,
    role: role_from_string(role),
    password_hash:,
    created_at:,
  ))
}

fn token_decoder() -> decode.Decoder(Token) {
  use id <- decode.field(0, decode.string)
  use user_id <- decode.field(1, decode.string)
  use prefix <- decode.field(2, decode.string)
  use label <- decode.field(3, decode.string)
  use created_at <- decode.field(4, decode.int)
  use expires <- decode.field(5, decode.optional(decode.int))
  use last_access <- decode.field(6, decode.optional(decode.int))
  decode.success(identity.Token(
    id:,
    user_id:,
    prefix:,
    label:,
    created_at:,
    expires:,
    last_access:,
  ))
}

fn rule_decoder() -> decode.Decoder(acl.Rule) {
  use username <- decode.field(0, decode.string)
  use pattern <- decode.field(1, decode.string)
  use read <- decode.field(2, decode.int)
  use write <- decode.field(3, decode.int)
  decode.success(acl.Rule(
    username:,
    topic_pattern: pattern,
    permission: identity.permission_from_bits(read != 0, write != 0),
  ))
}

fn authorization_row_decoder() -> decode.Decoder(AuthorizationRow) {
  use setup_required <- decode.field(0, decode.int)
  use read <- decode.field(1, decode.int)
  use write <- decode.field(2, decode.int)
  use has_rule <- decode.field(3, decode.int)
  use username <- decode.field(4, decode.string)
  use pattern <- decode.field(5, decode.string)
  use rule_read <- decode.field(6, decode.int)
  use rule_write <- decode.field(7, decode.int)
  let rule = case has_rule == 0 {
    True -> None
    False ->
      Some(acl.Rule(
        username:,
        topic_pattern: pattern,
        permission: identity.permission_from_bits(
          rule_read != 0,
          rule_write != 0,
        ),
      ))
  }
  decode.success(AuthorizationRow(
    setup_required: setup_required != 0,
    default_access: identity.permission_from_bits(read != 0, write != 0),
    rule:,
  ))
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.User -> "user"
    acl.Admin -> "admin"
  }
}

fn role_from_string(role: String) -> acl.Role {
  case role {
    "admin" -> acl.Admin
    _ -> acl.User
  }
}

fn in_transaction(
  connection: Connection,
  operation: fn() -> Result(a, identity.Error),
) -> Result(a, identity.Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  case operation() {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
    Ok(value) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(map_error(error))
        }
      }
  }
}

fn map_error(error: sqlight.Error) -> identity.Error {
  let sqlight.SqlightError(code:, message:, ..) = error
  case code {
    sqlight.Constraint
    | sqlight.ConstraintPrimarykey
    | sqlight.ConstraintRowid
    | sqlight.ConstraintUnique -> identity.Conflict(message)
    sqlight.Corrupt | sqlight.Notadb -> identity.Corrupt(message)
    _ -> identity.Unavailable(message)
  }
}
