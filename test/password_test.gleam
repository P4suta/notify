import gleam/string
import notify/security/password

pub fn new_passwords_use_argon2id_and_verify_test() {
  let assert Ok(hash) = password.hash("correct horse battery staple")
  assert string.starts_with(hash, "$argon2id$")
  assert password.verify(hash, "correct horse battery staple") == Ok(True)
  assert password.verify(hash, "wrong password") == Ok(False)
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
