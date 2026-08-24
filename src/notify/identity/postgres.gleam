import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/core/acl
import notify/identity.{type Store, type Token, type User}
import notify/security/token as security_token
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

pub type Started {
  Started(store: Store, setup_token: Option(String))
}

type Command {
  SetupRequired(Subject(Result(Bool, identity.Error)))
  IssueSetup(String, Int, Int, Subject(Result(Bool, identity.Error)))
  CompleteSetup(identity.Setup, Subject(Result(User, identity.Error)))
  UserByName(String, Subject(Result(User, identity.Error)))
  UserByTokenHash(String, Int, Subject(Result(User, identity.Error)))
  DefaultAccess(Subject(Result(acl.Permission, identity.Error)))
  SetDefaultAccess(
    acl.Permission,
    Subject(Result(acl.Permission, identity.Error)),
  )
  RulesFor(String, Subject(Result(List(acl.Rule), identity.Error)))
  AddUser(identity.NewUser, Subject(Result(User, identity.Error)))
  ListUsers(Subject(Result(List(User), identity.Error)))
  DeleteUser(String, Subject(Result(Nil, identity.Error)))
  ChangePassword(String, String, Subject(Result(Nil, identity.Error)))
  AddToken(identity.NewToken, Subject(Result(Token, identity.Error)))
  ListTokens(String, Subject(Result(List(Token), identity.Error)))
  RevokeToken(String, Subject(Result(Nil, identity.Error)))
  RevokeTokenHash(String, Subject(Result(Nil, identity.Error)))
  PutGrant(acl.Rule, Subject(Result(acl.Rule, identity.Error)))
  DeleteGrant(String, String, Subject(Result(Nil, identity.Error)))
  ListGrants(Option(String), Subject(Result(List(acl.Rule), identity.Error)))
}

const setup_lifetime_seconds = 900

const migration = "
CREATE TABLE IF NOT EXISTS notify_auth_state (
  id SMALLINT PRIMARY KEY CHECK (id = 1),
  setup_complete BOOLEAN NOT NULL DEFAULT FALSE,
  anonymous_read BOOLEAN NOT NULL DEFAULT FALSE,
  anonymous_write BOOLEAN NOT NULL DEFAULT FALSE
);
INSERT INTO notify_auth_state(id) VALUES (1) ON CONFLICT(id) DO NOTHING;

CREATE TABLE IF NOT EXISTS notify_setup_challenge (
  id SMALLINT PRIMARY KEY CHECK (id = 1),
  token_hash TEXT NOT NULL,
  expires BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS notify_users (
  id TEXT PRIMARY KEY,
  username TEXT NOT NULL UNIQUE,
  role TEXT NOT NULL CHECK (role IN ('user', 'admin')),
  password_hash TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS notify_access_tokens (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES notify_users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  token_prefix TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  expires BIGINT
);
CREATE INDEX IF NOT EXISTS notify_access_tokens_user
  ON notify_access_tokens(user_id);

CREATE TABLE IF NOT EXISTS notify_acl_rules (
  id BIGSERIAL PRIMARY KEY,
  username TEXT NOT NULL,
  topic_pattern TEXT NOT NULL,
  readable BOOLEAN NOT NULL,
  writable BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(username, topic_pattern)
);
CREATE INDEX IF NOT EXISTS notify_acl_rules_username
  ON notify_acl_rules(username);
"

pub fn start(
  config: Config,
  now: fn() -> Int,
  setup_entropy: fn() -> String,
) -> Result(Started, identity.Error) {
  use store <- result.try(open_store(config))
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

pub fn open_store(config: Config) -> Result(Store, identity.Error) {
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_actor(connection)
  }
}

fn start_actor(
  connection: postgleam.Connection,
) -> Result(Store, identity.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      identity.Unavailable("PostgreSQL identity actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    identity.Store(
      setup_required: fn() { process.call(subject, 30_000, SetupRequired) },
      issue_setup: fn(hash, expires, now) {
        process.call(subject, 30_000, fn(reply) {
          IssueSetup(hash, expires, now, reply)
        })
      },
      complete_setup: fn(setup) {
        process.call(subject, 60_000, fn(reply) { CompleteSetup(setup, reply) })
      },
      user_by_name: fn(username) {
        process.call(subject, 30_000, fn(reply) { UserByName(username, reply) })
      },
      user_by_token_hash: fn(hash, now) {
        process.call(subject, 30_000, fn(reply) {
          UserByTokenHash(hash, now, reply)
        })
      },
      default_access: fn() { process.call(subject, 30_000, DefaultAccess) },
      set_default_access: fn(permission) {
        process.call(subject, 30_000, fn(reply) {
          SetDefaultAccess(permission, reply)
        })
      },
      rules_for: fn(username) {
        process.call(subject, 30_000, fn(reply) { RulesFor(username, reply) })
      },
      add_user: fn(user) {
        process.call(subject, 60_000, fn(reply) { AddUser(user, reply) })
      },
      list_users: fn() { process.call(subject, 30_000, ListUsers) },
      delete_user: fn(username) {
        process.call(subject, 30_000, fn(reply) { DeleteUser(username, reply) })
      },
      change_password: fn(username, hash) {
        process.call(subject, 30_000, fn(reply) {
          ChangePassword(username, hash, reply)
        })
      },
      add_token: fn(token) {
        process.call(subject, 30_000, fn(reply) { AddToken(token, reply) })
      },
      list_tokens: fn(user_id) {
        process.call(subject, 30_000, fn(reply) { ListTokens(user_id, reply) })
      },
      revoke_token: fn(id) {
        process.call(subject, 30_000, fn(reply) { RevokeToken(id, reply) })
      },
      revoke_token_hash: fn(hash) {
        process.call(subject, 30_000, fn(reply) { RevokeTokenHash(hash, reply) })
      },
      put_grant: fn(rule) {
        process.call(subject, 30_000, fn(reply) { PutGrant(rule, reply) })
      },
      delete_grant: fn(username, pattern) {
        process.call(subject, 30_000, fn(reply) {
          DeleteGrant(username, pattern, reply)
        })
      },
      list_grants: fn(username) {
        process.call(subject, 30_000, fn(reply) { ListGrants(username, reply) })
      },
    ),
  )
}

fn handle(
  connection: postgleam.Connection,
  command: Command,
) -> actor.Next(postgleam.Connection, Command) {
  case command {
    SetupRequired(reply) ->
      respond(connection, reply, setup_required(connection))
    IssueSetup(hash, expires, now, reply) ->
      respond(connection, reply, issue_setup(connection, hash, expires, now))
    CompleteSetup(setup, reply) ->
      respond(connection, reply, complete_setup(connection, setup))
    UserByName(username, reply) ->
      respond(connection, reply, user_by_name(connection, username))
    UserByTokenHash(hash, now, reply) ->
      respond(connection, reply, user_by_token_hash(connection, hash, now))
    DefaultAccess(reply) ->
      respond(connection, reply, default_access(connection))
    SetDefaultAccess(permission, reply) ->
      respond(connection, reply, set_default_access(connection, permission))
    RulesFor(username, reply) ->
      respond(connection, reply, rules_for(connection, username))
    AddUser(user, reply) ->
      respond(connection, reply, add_user(connection, user))
    ListUsers(reply) -> respond(connection, reply, list_users(connection))
    DeleteUser(username, reply) ->
      respond(connection, reply, delete_user(connection, username))
    ChangePassword(username, hash, reply) ->
      respond(connection, reply, change_password(connection, username, hash))
    AddToken(token, reply) ->
      respond(connection, reply, add_token(connection, token))
    ListTokens(user_id, reply) ->
      respond(connection, reply, list_tokens(connection, user_id))
    RevokeToken(id, reply) ->
      respond(connection, reply, revoke_token(connection, id))
    RevokeTokenHash(hash, reply) ->
      respond(connection, reply, revoke_token_hash(connection, hash))
    PutGrant(rule, reply) ->
      respond(connection, reply, put_grant(connection, rule))
    DeleteGrant(username, pattern, reply) ->
      respond(connection, reply, delete_grant(connection, username, pattern))
    ListGrants(username, reply) ->
      respond(connection, reply, list_grants(connection, username))
  }
}

fn respond(
  connection: postgleam.Connection,
  reply: Subject(a),
  value: a,
) -> actor.Next(postgleam.Connection, Command) {
  process.send(reply, value)
  actor.continue(connection)
}

fn migrate(connection: postgleam.Connection) -> Result(Nil, identity.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_843),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, migration))
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn setup_required(
  connection: postgleam.Connection,
) -> Result(Bool, identity.Error) {
  postgleam.query_one(
    connection,
    "SELECT setup_complete FROM notify_auth_state WHERE id = 1",
    [],
    {
      use complete <- decode.element(0, decode.bool)
      decode.success(!complete)
    },
  )
  |> result.map_error(map_error)
}

fn issue_setup(
  connection: postgleam.Connection,
  hash: String,
  expires: Int,
  now: Int,
) -> Result(Bool, identity.Error) {
  postgleam.transaction(connection, fn(tx) {
    use required <- result.try(setup_required_pg(tx))
    case required {
      False -> Error(postgleam.query_error("setup already complete"))
      True -> {
        use active <- result.try(
          postgleam.query_with(
            tx,
            "SELECT 1::bigint FROM notify_setup_challenge WHERE id = 1 AND expires > $1 FOR UPDATE",
            [postgleam.int(now)],
            {
              use found <- decode.element(0, decode.int)
              decode.success(found)
            },
          ),
        )
        case active.rows {
          [_] -> Ok(False)
          [] ->
            postgleam.query(
              tx,
              "INSERT INTO notify_setup_challenge(id, token_hash, expires) VALUES (1, $1, $2) ON CONFLICT(id) DO UPDATE SET token_hash = excluded.token_hash, expires = excluded.expires",
              [postgleam.text(hash), postgleam.int(expires)],
            )
            |> result.map(fn(_) { True })
          _ -> Error(postgleam.query_error("multiple setup challenges"))
        }
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("setup already complete") ->
        identity.SetupAlreadyComplete
      other -> map_error(other)
    }
  })
}

fn setup_required_pg(
  connection: postgleam.Connection,
) -> Result(Bool, pg_error.Error) {
  postgleam.query_one(
    connection,
    "SELECT setup_complete FROM notify_auth_state WHERE id = 1 FOR UPDATE",
    [],
    {
      use complete <- decode.element(0, decode.bool)
      decode.success(!complete)
    },
  )
}

fn complete_setup(
  connection: postgleam.Connection,
  setup: identity.Setup,
) -> Result(User, identity.Error) {
  postgleam.transaction(connection, fn(tx) {
    use required <- result.try(setup_required_pg(tx))
    case required {
      False -> Error(postgleam.query_error("setup already complete"))
      True -> {
        use challenge <- result.try(
          postgleam.query_with(
            tx,
            "SELECT 1::bigint FROM notify_setup_challenge WHERE id = 1 AND token_hash = $1 AND expires >= $2 FOR UPDATE",
            [postgleam.text(setup.token_hash), postgleam.int(setup.now)],
            {
              use found <- decode.element(0, decode.int)
              decode.success(found)
            },
          ),
        )
        case challenge.rows {
          [] -> Error(postgleam.query_error("invalid setup token"))
          [_] -> {
            let user =
              identity.User(
                id: setup.user_id,
                username: setup.username,
                role: acl.Admin,
                password_hash: setup.password_hash,
                created_at: setup.now,
              )
            use _ <- result.try(insert_user_pg(tx, user))
            let #(read, write) =
              identity.permission_bits(setup.anonymous_access)
            use _ <- result.try(
              postgleam.query(
                tx,
                "UPDATE notify_auth_state SET setup_complete = TRUE, anonymous_read = $1, anonymous_write = $2 WHERE id = 1",
                [postgleam.bool(read), postgleam.bool(write)],
              ),
            )
            use _ <- result.try(
              postgleam.query(tx, "DELETE FROM notify_setup_challenge", []),
            )
            Ok(user)
          }
          _ -> Error(postgleam.query_error("multiple setup challenges"))
        }
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("setup already complete") ->
        identity.SetupAlreadyComplete
      pg_error.ConnectionError("invalid setup token") ->
        identity.InvalidSetupToken
      other -> map_error(other)
    }
  })
}

fn user_by_name(
  connection: postgleam.Connection,
  username: String,
) -> Result(User, identity.Error) {
  query_one_user(
    connection,
    "SELECT id, username, role, password_hash, created_at FROM notify_users WHERE username = $1",
    [postgleam.text(username)],
  )
}

fn user_by_token_hash(
  connection: postgleam.Connection,
  hash: String,
  now: Int,
) -> Result(User, identity.Error) {
  query_one_user(
    connection,
    "SELECT u.id, u.username, u.role, u.password_hash, u.created_at FROM notify_users u JOIN notify_access_tokens t ON t.user_id = u.id WHERE t.token_hash = $1 AND (t.expires IS NULL OR t.expires >= $2)",
    [postgleam.text(hash), postgleam.int(now)],
  )
}

fn default_access(
  connection: postgleam.Connection,
) -> Result(acl.Permission, identity.Error) {
  postgleam.query_one(
    connection,
    "SELECT anonymous_read, anonymous_write FROM notify_auth_state WHERE id = 1",
    [],
    {
      use read <- decode.element(0, decode.bool)
      use write <- decode.element(1, decode.bool)
      decode.success(identity.permission_from_bits(read, write))
    },
  )
  |> result.map_error(map_error)
}

fn set_default_access(
  connection: postgleam.Connection,
  permission: acl.Permission,
) -> Result(acl.Permission, identity.Error) {
  let #(read, write) = identity.permission_bits(permission)
  postgleam.query(
    connection,
    "UPDATE notify_auth_state SET anonymous_read = $1, anonymous_write = $2 WHERE id = 1 AND setup_complete = TRUE",
    [postgleam.bool(read), postgleam.bool(write)],
  )
  |> result.map(fn(_) { permission })
  |> result.map_error(map_error)
}

fn rules_for(
  connection: postgleam.Connection,
  username: String,
) -> Result(List(acl.Rule), identity.Error) {
  query_rules(
    connection,
    "SELECT username, topic_pattern, readable, writable FROM notify_acl_rules WHERE username = $1 OR username = '*'",
    [postgleam.text(username)],
  )
}

fn add_user(
  connection: postgleam.Connection,
  new_user: identity.NewUser,
) -> Result(User, identity.Error) {
  let identity.NewUser(id:, username:, role:, password_hash:, created_at:) =
    new_user
  let user = identity.User(id:, username:, role:, password_hash:, created_at:)
  insert_user_pg(connection, user)
  |> result.map(fn(_) { user })
  |> result.map_error(map_error)
}

fn insert_user_pg(
  connection: postgleam.Connection,
  user: User,
) -> Result(Nil, pg_error.Error) {
  postgleam.query(
    connection,
    "INSERT INTO notify_users(id, username, role, password_hash, created_at) VALUES ($1, $2, $3, $4, $5)",
    [
      postgleam.text(user.id),
      postgleam.text(user.username),
      postgleam.text(role_string(user.role)),
      postgleam.text(user.password_hash),
      postgleam.int(user.created_at),
    ],
  )
  |> result.map(fn(_) { Nil })
}

fn list_users(
  connection: postgleam.Connection,
) -> Result(List(User), identity.Error) {
  postgleam.query_with(
    connection,
    "SELECT id, username, role, password_hash, created_at FROM notify_users ORDER BY username ASC",
    [],
    user_decoder(),
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn delete_user(
  connection: postgleam.Connection,
  username: String,
) -> Result(Nil, identity.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "DELETE FROM notify_acl_rules WHERE username = $1", [
        postgleam.text(username),
      ]),
    )
    use _ <- result.try(
      postgleam.query(tx, "DELETE FROM notify_users WHERE username = $1", [
        postgleam.text(username),
      ]),
    )
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn change_password(
  connection: postgleam.Connection,
  username: String,
  hash: String,
) -> Result(Nil, identity.Error) {
  postgleam.query(
    connection,
    "UPDATE notify_users SET password_hash = $1 WHERE username = $2",
    [postgleam.text(hash), postgleam.text(username)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn add_token(
  connection: postgleam.Connection,
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
  postgleam.query(
    connection,
    "INSERT INTO notify_access_tokens(id, user_id, token_hash, token_prefix, label, created_at, expires) VALUES ($1, $2, $3, $4, $5, $6, $7)",
    [
      postgleam.text(id),
      postgleam.text(user_id),
      postgleam.text(token_hash),
      postgleam.text(prefix),
      postgleam.text(label),
      postgleam.int(created_at),
      postgleam.nullable(expires, postgleam.int),
    ],
  )
  |> result.map(fn(_) {
    identity.Token(id:, user_id:, prefix:, label:, created_at:, expires:)
  })
  |> result.map_error(map_error)
}

fn list_tokens(
  connection: postgleam.Connection,
  user_id: String,
) -> Result(List(Token), identity.Error) {
  postgleam.query_with(
    connection,
    "SELECT id, user_id, token_prefix, label, created_at, expires FROM notify_access_tokens WHERE user_id = $1 ORDER BY created_at DESC, id ASC",
    [postgleam.text(user_id)],
    token_decoder(),
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn revoke_token(
  connection: postgleam.Connection,
  id: String,
) -> Result(Nil, identity.Error) {
  postgleam.query(connection, "DELETE FROM notify_access_tokens WHERE id = $1", [
    postgleam.text(id),
  ])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn revoke_token_hash(
  connection: postgleam.Connection,
  hash: String,
) -> Result(Nil, identity.Error) {
  postgleam.query(
    connection,
    "DELETE FROM notify_access_tokens WHERE token_hash = $1",
    [postgleam.text(hash)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn put_grant(
  connection: postgleam.Connection,
  rule: acl.Rule,
) -> Result(acl.Rule, identity.Error) {
  let acl.Rule(username:, topic_pattern:, permission:) = rule
  let #(read, write) = identity.permission_bits(permission)
  postgleam.query(
    connection,
    "INSERT INTO notify_acl_rules(username, topic_pattern, readable, writable) VALUES ($1, $2, $3, $4) ON CONFLICT(username, topic_pattern) DO UPDATE SET readable = excluded.readable, writable = excluded.writable",
    [
      postgleam.text(username),
      postgleam.text(topic_pattern),
      postgleam.bool(read),
      postgleam.bool(write),
    ],
  )
  |> result.map(fn(_) { rule })
  |> result.map_error(map_error)
}

fn delete_grant(
  connection: postgleam.Connection,
  username: String,
  pattern: String,
) -> Result(Nil, identity.Error) {
  postgleam.query(
    connection,
    "DELETE FROM notify_acl_rules WHERE username = $1 AND topic_pattern = $2",
    [postgleam.text(username), postgleam.text(pattern)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn list_grants(
  connection: postgleam.Connection,
  username: Option(String),
) -> Result(List(acl.Rule), identity.Error) {
  case username {
    None ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM notify_acl_rules ORDER BY username, topic_pattern",
        [],
      )
    Some(username) ->
      query_rules(
        connection,
        "SELECT username, topic_pattern, readable, writable FROM notify_acl_rules WHERE username = $1 ORDER BY topic_pattern",
        [postgleam.text(username)],
      )
  }
}

fn query_rules(
  connection: postgleam.Connection,
  statement: String,
  parameters: List(postgleam.Param),
) -> Result(List(acl.Rule), identity.Error) {
  postgleam.query_with(connection, statement, parameters, rule_decoder())
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn query_one_user(
  connection: postgleam.Connection,
  statement: String,
  parameters: List(postgleam.Param),
) -> Result(User, identity.Error) {
  use response <- result.try(
    postgleam.query_with(connection, statement, parameters, user_decoder())
    |> result.map_error(map_error),
  )
  case response.rows {
    [user] -> Ok(user)
    [] -> Error(identity.NotFound)
    _ -> Error(identity.Corrupt("identity lookup returned multiple users"))
  }
}

fn user_decoder() -> decode.RowDecoder(User) {
  use id <- decode.element(0, decode.text)
  use username <- decode.element(1, decode.text)
  use role <- decode.element(2, decode.text)
  use password_hash <- decode.element(3, decode.text)
  use created_at <- decode.element(4, decode.int)
  decode.success(identity.User(
    id:,
    username:,
    role: role_from_string(role),
    password_hash:,
    created_at:,
  ))
}

fn token_decoder() -> decode.RowDecoder(Token) {
  use id <- decode.element(0, decode.text)
  use user_id <- decode.element(1, decode.text)
  use prefix <- decode.element(2, decode.text)
  use label <- decode.element(3, decode.text)
  use created_at <- decode.element(4, decode.int)
  use expires <- decode.element(5, decode.optional(decode.int))
  decode.success(identity.Token(
    id:,
    user_id:,
    prefix:,
    label:,
    created_at:,
    expires:,
  ))
}

fn rule_decoder() -> decode.RowDecoder(acl.Rule) {
  use username <- decode.element(0, decode.text)
  use pattern <- decode.element(1, decode.text)
  use read <- decode.element(2, decode.bool)
  use write <- decode.element(3, decode.bool)
  decode.success(acl.Rule(
    username:,
    topic_pattern: pattern,
    permission: identity.permission_from_bits(read, write),
  ))
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.Admin -> "admin"
    acl.User -> "user"
  }
}

fn role_from_string(role: String) -> acl.Role {
  case role {
    "admin" -> acl.Admin
    _ -> acl.User
  }
}

fn map_error(error: pg_error.Error) -> identity.Error {
  case error {
    pg_error.PgError(fields, _, _) if fields.code == "23505" ->
      identity.Conflict(fields.message)
    pg_error.PgError(fields, _, _) ->
      identity.Unavailable(
        "PostgreSQL " <> fields.code <> ": " <> fields.message,
      )
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> identity.Unavailable(detail)
    pg_error.DecodeError(detail) -> identity.Corrupt(detail)
    pg_error.TimeoutError ->
      identity.Unavailable("PostgreSQL request timed out")
  }
}
