import argus
import beecrypt
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const minimum_length = 12

const maximum_length = 1024

pub type Error {
  TooShort
  TooLong
  HashFailed(argus.HashError)
}

pub fn hash(value: String) -> Result(String, Error) {
  case string.length(value) {
    length if length < minimum_length -> Error(TooShort)
    length if length > maximum_length -> Error(TooLong)
    _ -> hash_unchecked(value)
  }
}

/// Rehashes a successfully verified legacy credential. ntfy historically
/// allowed passwords shorter than Notify's policy; rejecting them here would
/// lock migrated users out before they can change their password.
pub fn hash_legacy_upgrade(value: String) -> Result(String, Error) {
  case string.length(value) > maximum_length {
    True -> Error(TooLong)
    False -> hash_unchecked(value)
  }
}

fn hash_unchecked(value: String) -> Result(String, Error) {
  argus.hasher()
  |> argus.hash(value, argus.gen_salt())
  |> result.map(fn(hashes) { hashes.encoded_hash })
  |> result.map_error(HashFailed)
}

pub fn verify(encoded_hash: String, candidate: String) -> Result(Bool, Error) {
  case needs_rehash(encoded_hash) {
    True ->
      case valid_legacy_hash(encoded_hash) {
        True -> Ok(beecrypt.verify(candidate, normalise_bcrypt(encoded_hash)))
        False -> Ok(False)
      }
    False ->
      argus.verify(encoded_hash, candidate) |> result.map_error(HashFailed)
  }
}

pub fn valid_legacy_hash(encoded_hash: String) -> Bool {
  case string.split(encoded_hash, "$"), string.length(encoded_hash) == 60 {
    ["", version, cost, payload], True ->
      list.contains(["2a", "2b", "2y"], version)
      && case int.parse(cost) {
        Ok(cost) -> cost >= 4 && cost <= 31
        Error(_) -> False
      }
      && string.length(payload) == 53
      && payload
      |> string.to_graphemes
      |> list.all(fn(character) {
        string.contains(
          "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
          character,
        )
      })
    _, _ -> False
  }
}

/// ntfy stores bcrypt credentials. They are accepted only as a migration
/// bridge and must be replaced with Argon2id after the first valid login.
pub fn needs_rehash(encoded_hash: String) -> Bool {
  string.starts_with(encoded_hash, "$2a$")
  || string.starts_with(encoded_hash, "$2b$")
  || string.starts_with(encoded_hash, "$2y$")
}

fn normalise_bcrypt(encoded_hash: String) -> String {
  case string.starts_with(encoded_hash, "$2y$") {
    True -> "$2a$" <> string.drop_start(encoded_hash, 4)
    False -> encoded_hash
  }
}
