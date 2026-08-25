import gleam/crypto
import gleam/list
import gleam/string

const entropy_length = 29

pub type IssuedToken {
  IssuedToken(value: String, hash: String)
}

pub type Error {
  InvalidEntropy
}

pub fn issue(entropy: fn() -> String) -> Result(IssuedToken, Error) {
  issue_with_prefix("tk_", entropy)
}

pub fn issue_setup(entropy: fn() -> String) -> Result(IssuedToken, Error) {
  issue_with_prefix("su_", entropy)
}

fn issue_with_prefix(
  prefix: String,
  entropy: fn() -> String,
) -> Result(IssuedToken, Error) {
  let random = entropy()
  case string.length(random) == entropy_length && ascii_alphanumeric(random) {
    False -> Error(InvalidEntropy)
    True -> {
      let value = prefix <> random
      Ok(IssuedToken(value:, hash: digest(value)))
    }
  }
}

pub fn generate() -> Result(IssuedToken, Error) {
  issue(random_token_entropy)
}

pub fn generate_setup() -> Result(IssuedToken, Error) {
  issue_setup(random_token_entropy)
}

pub fn secure_entropy() -> String {
  random_token_entropy()
}

pub fn digest(value: String) -> String {
  sha256_hex(value)
}

/// Compares secret-derived strings without data-dependent early exit.
pub fn secure_equal(left: String, right: String) -> Bool {
  crypto.secure_compare(<<left:utf8>>, <<right:utf8>>)
}

fn ascii_alphanumeric(value: String) -> Bool {
  value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      character,
    )
  })
}

@external(erlang, "notify_ffi", "random_token_entropy")
fn random_token_entropy() -> String

@external(erlang, "notify_ffi", "sha256_hex")
fn sha256_hex(value: String) -> String
