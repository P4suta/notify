import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import notify/core/acl
import notify/core/topic.{type Topic}
import notify/identity
import notify/security/password
import notify/security/token as security_token

const token_issue_attempts = 8

pub type Credentials {
  NoCredentials
  Basic(username: String, password: String)
  Bearer(token: String)
}

pub type Error {
  SetupRequired
  InvalidSetupToken
  SetupAlreadyComplete
  InvalidCredentials
  InvalidUsername
  InvalidTopicPattern
  InvalidTokenLabel
  LastAdmin
  PasswordError(password.Error)
  IdentityError(identity.Error)
  TokenError(security_token.Error)
}

pub opaque type Access {
  OpenAccess
  ManagedAccess(store: identity.Store, dummy_password_hash: String)
}

pub fn open() -> Access {
  OpenAccess
}

pub fn is_managed(access: Access) -> Bool {
  case access {
    OpenAccess -> False
    ManagedAccess(_, _) -> True
  }
}

pub fn managed(store: identity.Store) -> Result(Access, Error) {
  password.hash("notify timing equalisation password")
  |> result.map(fn(hash) { ManagedAccess(store:, dummy_password_hash: hash) })
  |> result.map_error(PasswordError)
}

pub fn setup_required(access: Access) -> Result(Bool, Error) {
  case access {
    OpenAccess -> Ok(False)
    ManagedAccess(store, _) ->
      store.setup_required() |> result.map_error(IdentityError)
  }
}

pub fn complete_setup(
  access: Access,
  setup_token: String,
  user_id: String,
  username: String,
  raw_password: String,
  anonymous_access: acl.Permission,
  now: Int,
) -> Result(identity.User, Error) {
  case access {
    OpenAccess -> Error(SetupAlreadyComplete)
    ManagedAccess(store, _) -> {
      use _ <- result.try(validate_username(username))
      use _ <- result.try(validate_setup_token(setup_token))
      use password_hash <- result.try(
        password.hash(raw_password) |> result.map_error(PasswordError),
      )
      store.complete_setup(identity.Setup(
        token_hash: security_token.digest(setup_token),
        user_id:,
        username:,
        password_hash:,
        anonymous_access:,
        now:,
      ))
      |> result.map_error(map_identity_error)
    }
  }
}

pub fn authenticate(
  access: Access,
  credentials: Credentials,
  now: Int,
) -> Result(acl.Principal, Error) {
  case access, credentials {
    OpenAccess, _ -> Ok(acl.Anonymous)
    ManagedAccess(_, _), NoCredentials -> Ok(acl.Anonymous)
    ManagedAccess(store, dummy_hash), Basic(username, candidate) ->
      authenticate_basic(store, dummy_hash, username, candidate)
    ManagedAccess(store, _), Bearer(raw_token) ->
      case valid_bearer(raw_token) {
        False -> Error(InvalidCredentials)
        True ->
          store.user_by_token_hash(security_token.digest(raw_token), now)
          |> result.map(fn(user) { acl.Authenticated(user.username, user.role) })
          |> result.map_error(fn(_) { InvalidCredentials })
      }
  }
}

fn authenticate_basic(
  store: identity.Store,
  dummy_hash: String,
  username: String,
  candidate: String,
) -> Result(acl.Principal, Error) {
  case store.user_by_name(username) {
    Ok(user) ->
      case password.verify(user.password_hash, candidate) {
        Ok(True) -> {
          use _ <- result.try(upgrade_legacy_password(store, user, candidate))
          Ok(acl.Authenticated(user.username, user.role))
        }
        Ok(False) | Error(_) -> Error(InvalidCredentials)
      }
    Error(identity.NotFound) -> {
      let _ = password.verify(dummy_hash, candidate)
      Error(InvalidCredentials)
    }
    Error(error) -> Error(IdentityError(error))
  }
}

fn upgrade_legacy_password(
  store: identity.Store,
  user: identity.User,
  candidate: String,
) -> Result(Nil, Error) {
  case password.needs_rehash(user.password_hash) {
    False -> Ok(Nil)
    True -> {
      use replacement <- result.try(
        password.hash_legacy_upgrade(candidate)
        |> result.map_error(PasswordError),
      )
      store.change_password(user.username, replacement)
      |> result.map_error(IdentityError)
    }
  }
}

pub fn authorize(
  access: Access,
  principal: acl.Principal,
  topics: List(Topic),
  operation: acl.Operation,
) -> Result(Bool, Error) {
  case access {
    OpenAccess -> Ok(True)
    ManagedAccess(store, _) -> {
      let username = case principal {
        acl.Anonymous -> "*"
        acl.Authenticated(username, _) -> username
      }
      use policy <- result.try(
        store.authorization_policy(username) |> result.map_error(IdentityError),
      )
      case policy.setup_required {
        True -> Error(SetupRequired)
        False -> {
          Ok(
            list.all(topics, fn(topic) {
              acl.authorize(
                principal,
                topic.to_string(topic),
                operation,
                policy.rules,
                policy.default_access,
              )
            }),
          )
        }
      }
    }
  }
}

pub fn add_user(
  access: Access,
  id: String,
  username: String,
  raw_password: String,
  role: acl.Role,
  now: Int,
) -> Result(identity.User, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) -> {
      use _ <- result.try(validate_username(username))
      use password_hash <- result.try(
        password.hash(raw_password) |> result.map_error(PasswordError),
      )
      store.add_user(identity.NewUser(
        id:,
        username:,
        role:,
        password_hash:,
        created_at: now,
      ))
      |> result.map_error(IdentityError)
    }
  }
}

pub fn create_token(
  access: Access,
  next_id: fn() -> String,
  user_id: String,
  label: String,
  expires: Option(Int),
  now: Int,
  entropy: fn() -> String,
) -> Result(#(identity.Token, String), Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) -> {
      use _ <- result.try(validate_token_label(label))
      create_token_attempt(
        store,
        next_id,
        user_id,
        label,
        expires,
        now,
        entropy,
        token_issue_attempts,
      )
    }
  }
}

fn create_token_attempt(
  store: identity.Store,
  next_id: fn() -> String,
  user_id: String,
  label: String,
  expires: Option(Int),
  now: Int,
  entropy: fn() -> String,
  attempts_remaining: Int,
) -> Result(#(identity.Token, String), Error) {
  use issued <- result.try(
    security_token.issue(entropy) |> result.map_error(TokenError),
  )
  case
    store.add_token(identity.NewToken(
      id: next_id(),
      user_id:,
      token_hash: issued.hash,
      prefix: string.slice(issued.value, at_index: 0, length: 8),
      label:,
      created_at: now,
      expires:,
    ))
  {
    Error(identity.Conflict(_)) if attempts_remaining > 1 ->
      create_token_attempt(
        store,
        next_id,
        user_id,
        label,
        expires,
        now,
        entropy,
        attempts_remaining - 1,
      )
    Error(error) -> Error(IdentityError(error))
    Ok(stored) -> Ok(#(stored, issued.value))
  }
}

pub fn user_by_name(
  access: Access,
  username: String,
) -> Result(identity.User, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.user_by_name(username) |> result.map_error(IdentityError)
  }
}

pub fn list_users(access: Access) -> Result(List(identity.User), Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.list_users() |> result.map_error(IdentityError)
  }
}

pub fn page_users(
  access: Access,
  after: Option(String),
  limit: Int,
) -> Result(identity.Page(identity.User), Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.page_users(after, limit) |> result.map_error(IdentityError)
  }
}

pub fn delete_user(access: Access, username: String) -> Result(Nil, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) -> {
      use target <- result.try(
        store.user_by_name(username) |> result.map_error(IdentityError),
      )
      use users <- result.try(
        store.list_users() |> result.map_error(IdentityError),
      )
      let admin_count =
        users
        |> list.filter(fn(user) { user.role == acl.Admin })
        |> list.length
      case target.role == acl.Admin && admin_count <= 1 {
        True -> Error(LastAdmin)
        False -> store.delete_user(username) |> result.map_error(IdentityError)
      }
    }
  }
}

pub fn change_password(
  access: Access,
  username: String,
  raw_password: String,
) -> Result(Nil, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) -> {
      use _ <- result.try(
        store.user_by_name(username) |> result.map_error(IdentityError),
      )
      use hash <- result.try(
        password.hash(raw_password) |> result.map_error(PasswordError),
      )
      store.change_password(username, hash) |> result.map_error(IdentityError)
    }
  }
}

pub fn list_tokens(
  access: Access,
  username: String,
) -> Result(List(identity.Token), Error) {
  use user <- result.try(user_by_name(access, username))
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.list_tokens(user.id) |> result.map_error(IdentityError)
  }
}

pub fn page_tokens(
  access: Access,
  username: String,
  after: Option(String),
  limit: Int,
) -> Result(identity.Page(identity.Token), Error) {
  use user <- result.try(user_by_name(access, username))
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.page_tokens(user.id, after, limit)
      |> result.map_error(IdentityError)
  }
}

pub fn create_token_for_username(
  access: Access,
  next_id: fn() -> String,
  username: String,
  label: String,
  expires: Option(Int),
  now: Int,
  entropy: fn() -> String,
) -> Result(#(identity.Token, String), Error) {
  use user <- result.try(user_by_name(access, username))
  create_token(access, next_id, user.id, label, expires, now, entropy)
}

pub fn revoke_token(access: Access, id: String) -> Result(Nil, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.revoke_token(id) |> result.map_error(IdentityError)
  }
}

pub fn revoke_raw_token(access: Access, raw: String) -> Result(Nil, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.revoke_token_hash(security_token.digest(raw))
      |> result.map_error(IdentityError)
  }
}

pub fn default_access(access: Access) -> Result(acl.Permission, Error) {
  case access {
    OpenAccess -> Ok(acl.ReadWrite)
    ManagedAccess(store, _) ->
      store.default_access() |> result.map_error(IdentityError)
  }
}

pub fn set_default_access(
  access: Access,
  permission: acl.Permission,
) -> Result(acl.Permission, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.set_default_access(permission) |> result.map_error(IdentityError)
  }
}

pub fn list_grants(
  access: Access,
  username: Option(String),
) -> Result(List(acl.Rule), Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.list_grants(username) |> result.map_error(IdentityError)
  }
}

pub fn page_grants(
  access: Access,
  username: Option(String),
  after: Option(identity.GrantCursor),
  limit: Int,
) -> Result(identity.Page(acl.Rule), Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.page_grants(username, after, limit)
      |> result.map_error(IdentityError)
  }
}

pub fn revoke_grant(
  access: Access,
  username: String,
  pattern: String,
) -> Result(Nil, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) ->
      store.delete_grant(username, pattern) |> result.map_error(IdentityError)
  }
}

pub fn grant(
  access: Access,
  username: String,
  pattern: String,
  permission: acl.Permission,
) -> Result(acl.Rule, Error) {
  case access {
    OpenAccess ->
      Error(IdentityError(identity.Unavailable("identity disabled")))
    ManagedAccess(store, _) -> {
      use _ <- result.try(case username == "*" {
        True -> Ok(Nil)
        False -> validate_username(username)
      })
      use _ <- result.try(validate_topic_pattern(pattern))
      store.put_grant(acl.Rule(username:, topic_pattern: pattern, permission:))
      |> result.map_error(IdentityError)
    }
  }
}

fn validate_username(username: String) -> Result(Nil, Error) {
  let valid_characters =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.@"
  case
    string.length(username) >= 1
    && string.length(username) <= 64
    && username != "everyone"
    && username != "*"
    && username
    |> string.to_graphemes
    |> list.all(fn(character) { string.contains(valid_characters, character) })
  {
    True -> Ok(Nil)
    False -> Error(InvalidUsername)
  }
}

fn validate_topic_pattern(pattern: String) -> Result(Nil, Error) {
  let valid_characters =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*"
  case
    string.length(pattern) >= 1
    && string.length(pattern) <= 64
    && pattern
    |> string.to_graphemes
    |> list.all(fn(character) { string.contains(valid_characters, character) })
  {
    True -> Ok(Nil)
    False -> Error(InvalidTopicPattern)
  }
}

fn validate_token_label(label: String) -> Result(Nil, Error) {
  case string.length(label) <= 64 {
    True -> Ok(Nil)
    False -> Error(InvalidTokenLabel)
  }
}

fn validate_setup_token(value: String) -> Result(Nil, Error) {
  case string.length(value) == 32 && string.starts_with(value, "su_") {
    True -> Ok(Nil)
    False -> Error(InvalidSetupToken)
  }
}

fn valid_bearer(value: String) -> Bool {
  string.length(value) == 32 && string.starts_with(value, "tk_")
}

fn map_identity_error(error: identity.Error) -> Error {
  case error {
    identity.InvalidSetupToken -> InvalidSetupToken
    identity.SetupAlreadyComplete -> SetupAlreadyComplete
    other -> IdentityError(other)
  }
}
