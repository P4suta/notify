import argus
import gleam/string
import notify/security/password

pub fn new_passwords_use_argon2id_and_verify_test() {
  let assert Ok(hash) = password.hash("correct horse battery staple")
  assert string.starts_with(hash, "$argon2id$v=13$m=19456,t=2,p=1$")
  assert password.needs_rehash(hash) == False
  assert password.verify(hash, "correct horse battery staple") == Ok(True)
  assert password.verify(hash, "wrong password") == Ok(False)
}

pub fn valid_noncanonical_argon2_is_verified_and_requires_rehash_test() {
  let assert Ok(old) =
    argus.hasher()
    |> argus.time_cost(1)
    |> argus.memory_cost(8192)
    |> argus.hash("legacy argon password", argus.gen_salt())

  assert password.verify(old.encoded_hash, "legacy argon password") == Ok(True)
  assert password.verify(old.encoded_hash, "wrong password") == Ok(False)
  assert password.needs_rehash(old.encoded_hash) == True

  let standard_v19 =
    "$argon2id$v=19$m=256,t=2,p=1$c29tZXNhbHQ$nf65EOgLrQMR/uIPnA4rEsF5h7TKyQwu9U1bMCHGi/4"
  assert password.verify(standard_v19, "password") == Ok(True)
  assert password.needs_rehash(standard_v19) == True
}

pub fn weak_password_is_rejected_before_hashing_test() {
  assert password.hash("too-short") == Error(password.TooShort)
}

pub fn migrated_ntfy_bcrypt_is_verified_but_malformed_hashes_are_safe_test() {
  let hash = "$2a$10$YLiO8U21sX1uhZamTLJXHuxgVC0Z/GKISibrKCLohPgtG7yIxSk4C"
  assert password.valid_legacy_hash(hash)
  assert password.verify(hash, "phil") == Ok(True)
  assert password.verify(hash, "wrong") == Ok(False)
  assert password.verify("$2a$10$not-a-complete-hash", "anything") == Ok(False)
}
