import gleam/string
import notify/security/token

pub fn token_is_shown_once_but_only_hash_is_persistable_test() {
  let secret = "abcdefghijklmnopqrstuvwxyz123"
  let assert Ok(issued) = token.issue(fn() { secret })
  assert issued.value == "tk_" <> secret
  assert string.length(issued.value) == 32
  assert string.length(issued.hash) == 64
  assert !string.contains(issued.hash, secret)
  assert token.digest(issued.value) == issued.hash
}

pub fn malformed_entropy_source_is_rejected_test() {
  assert token.issue(fn() { "short" }) == Error(token.InvalidEntropy)
}
