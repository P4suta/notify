import gleam/option.{type Option}
import notify/core/acl.{type Permission, type Role}

pub type User {
  User(
    id: String,
    username: String,
    role: Role,
    password_hash: String,
    created_at: Int,
  )
}

pub type Setup {
  Setup(
    token_hash: String,
    user_id: String,
    username: String,
    password_hash: String,
    anonymous_access: Permission,
    now: Int,
  )
}

pub type NewUser {
  NewUser(
    id: String,
    username: String,
    role: Role,
    password_hash: String,
    created_at: Int,
  )
}

pub type NewToken {
  NewToken(
    id: String,
    user_id: String,
    token_hash: String,
    prefix: String,
    label: String,
    created_at: Int,
    expires: Option(Int),
  )
}

pub type Token {
  Token(
    id: String,
    user_id: String,
    prefix: String,
    label: String,
    created_at: Int,
    expires: Option(Int),
  )
}

pub type Error {
  Unavailable(String)
  Conflict(String)
  NotFound
  InvalidSetupToken
  SetupAlreadyComplete
  Corrupt(String)
}

pub type Store {
  Store(
    setup_required: fn() -> Result(Bool, Error),
    /// Atomically installs a setup challenge when no unexpired challenge is
    /// already active. `True` means the caller owns the raw one-time token and
    /// may display it; `False` prevents another node from advertising a token
    /// that was not persisted.
    issue_setup: fn(String, Int, Int) -> Result(Bool, Error),
    complete_setup: fn(Setup) -> Result(User, Error),
    user_by_name: fn(String) -> Result(User, Error),
    user_by_token_hash: fn(String, Int) -> Result(User, Error),
    default_access: fn() -> Result(Permission, Error),
    set_default_access: fn(Permission) -> Result(Permission, Error),
    rules_for: fn(String) -> Result(List(acl.Rule), Error),
    add_user: fn(NewUser) -> Result(User, Error),
    list_users: fn() -> Result(List(User), Error),
    delete_user: fn(String) -> Result(Nil, Error),
    change_password: fn(String, String) -> Result(Nil, Error),
    add_token: fn(NewToken) -> Result(Token, Error),
    list_tokens: fn(String) -> Result(List(Token), Error),
    revoke_token: fn(String) -> Result(Nil, Error),
    revoke_token_hash: fn(String) -> Result(Nil, Error),
    put_grant: fn(acl.Rule) -> Result(acl.Rule, Error),
    delete_grant: fn(String, String) -> Result(Nil, Error),
    list_grants: fn(Option(String)) -> Result(List(acl.Rule), Error),
  )
}

pub fn permission_bits(permission: Permission) -> #(Bool, Bool) {
  case permission {
    acl.Deny -> #(False, False)
    acl.ReadOnly -> #(True, False)
    acl.WriteOnly -> #(False, True)
    acl.ReadWrite -> #(True, True)
  }
}

pub fn permission_from_bits(read: Bool, write: Bool) -> Permission {
  case read, write {
    False, False -> acl.Deny
    True, False -> acl.ReadOnly
    False, True -> acl.WriteOnly
    True, True -> acl.ReadWrite
  }
}
