import gleam/option.{None, Some}
import notify/access
import notify/attachment_store/filesystem
import notify/core/acl
import notify/core/topic
import notify/identity/sqlite as identity_sqlite

const setup_entropy = "abcdefghijklmnopqrstuvwxyz123"

const user_token_entropy = "ZYXWVUTSRQPONMLKJIHGFEDCBA987"

pub fn active_setup_challenge_is_not_rotated_by_a_second_start_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let path = directory <> "/identity.db"
  let assert Ok(identity_sqlite.Started(first_store, Some(first_token))) =
    identity_sqlite.start(path, fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(identity_sqlite.Started(second_store, None)) =
    identity_sqlite.start(path, fn() { 1001 }, fn() { user_token_entropy })

  let assert Ok(first_access) = access.managed(first_store)
  let assert Ok(_) =
    access.complete_setup(
      first_access,
      first_token,
      "u_cluster_admin",
      "cluster-admin",
      "correct horse battery staple",
      acl.Deny,
      1002,
    )
  assert second_store.setup_required() == Ok(False)
}

pub fn expired_setup_challenge_can_be_replaced_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let path = directory <> "/identity.db"
  let assert Ok(identity_sqlite.Started(_, Some(first_token))) =
    identity_sqlite.start(path, fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(identity_sqlite.Started(second_store, Some(second_token))) =
    identity_sqlite.start(path, fn() { 1901 }, fn() { user_token_entropy })
  assert first_token != second_token

  let assert Ok(second_access) = access.managed(second_store)
  assert access.complete_setup(
      second_access,
      first_token,
      "u_old",
      "old-token",
      "correct horse battery staple",
      acl.Deny,
      1902,
    )
    == Error(access.InvalidSetupToken)
  let assert Ok(_) =
    access.complete_setup(
      second_access,
      second_token,
      "u_new",
      "new-token",
      "correct horse battery staple",
      acl.Deny,
      1902,
    )
}

pub fn setup_is_one_time_and_enables_argon2_basic_auth_test() {
  let assert Ok(identity_sqlite.Started(store, Some(setup_token))) =
    identity_sqlite.start(":memory:", fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(access) = access.managed(store)
  let assert Ok(topic) = topic.parse("private")

  assert access.setup_required(access) == Ok(True)
  assert access.authorize(access, acl.Anonymous, [topic], acl.Read)
    == Error(access.SetupRequired)
  assert access.complete_setup(
      access,
      "su_abcdefghijklmnopqrstuvwxyz124",
      "u_admin",
      "admin",
      "correct horse battery staple",
      acl.Deny,
      1001,
    )
    == Error(access.InvalidSetupToken)

  let assert Ok(admin) =
    access.complete_setup(
      access,
      setup_token,
      "u_admin",
      "admin",
      "correct horse battery staple",
      acl.Deny,
      1001,
    )
  assert admin.role == acl.Admin
  assert access.setup_required(access) == Ok(False)
  assert access.complete_setup(
      access,
      setup_token,
      "u_other",
      "other",
      "another secure password",
      acl.ReadWrite,
      1002,
    )
    == Error(access.SetupAlreadyComplete)

  let assert Ok(principal) =
    access.authenticate(
      access,
      access.Basic("admin", "correct horse battery staple"),
      1002,
    )
  assert principal == acl.Authenticated("admin", acl.Admin)
  assert access.authorize(access, principal, [topic], acl.Write) == Ok(True)
  assert access.authenticate(
      access,
      access.Basic("admin", "wrong password"),
      1002,
    )
    == Error(access.InvalidCredentials)
  assert access.authorize(access, acl.Anonymous, [topic], acl.Read) == Ok(False)
}

pub fn user_acl_and_hashed_bearer_token_work_together_test() {
  let assert Ok(identity_sqlite.Started(store, Some(setup_token))) =
    identity_sqlite.start(":memory:", fn() { 2000 }, fn() { setup_entropy })
  let assert Ok(access) = access.managed(store)
  let assert Ok(_) =
    access.complete_setup(
      access,
      setup_token,
      "u_admin",
      "admin",
      "correct horse battery staple",
      acl.Deny,
      2001,
    )
  let assert Ok(user) =
    access.add_user(
      access,
      "u_pat",
      "pat",
      "a different secure password",
      acl.User,
      2002,
    )
  let assert Ok(_) = access.grant(access, "pat", "jobs-*", acl.ReadWrite)
  let assert Ok(jobs) = topic.parse("jobs-nightly")
  let assert Ok(secret) = topic.parse("secret")

  let assert Ok(#(stored_token, raw_token)) =
    access.create_token(
      access,
      "tok_pat",
      user.id,
      "automation",
      None,
      2003,
      fn() { user_token_entropy },
    )
  assert stored_token.prefix == "tk_ZYXWV"
  assert stored_token.prefix != raw_token
  let assert Ok(principal) =
    access.authenticate(access, access.Bearer(raw_token), 2004)
  assert principal == acl.Authenticated("pat", acl.User)
  assert access.authorize(access, principal, [jobs], acl.Write) == Ok(True)
  assert access.authorize(access, principal, [secret], acl.Read) == Ok(False)
}
