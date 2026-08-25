import argus
import beecrypt
import gleam/int
import gleam/list
import gleam/result
import gleam/string

const minimum_length = 12

const maximum_length = 1024

const argon2_time_cost = 2

const argon2_memory_cost_kib = 19_456

const argon2_parallelism = 1

const argon2_hash_length = 32

// Jargon 1.1.0 passes numeric version 13 to its bundled Argon2 implementation
// and emits this exact PHC field. Keep it explicit so a dependency correction
// becomes a reviewed rehash-policy change instead of silent drift.
const argon2_phc_version = "v=13"

const argon2_phc_parameters = "m=19456,t=2,p=1"

// Argus generates 16 random bytes and passes their 24-byte base64 form to
// Jargon, which is then PHC-base64 encoded to 32 characters.
const argon2_encoded_salt_length = 32

const argon2_encoded_hash_length = 43

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
  configured_hasher()
  |> argus.hash(value, argus.gen_salt())
  |> result.map(fn(hashes) { hashes.encoded_hash })
  |> result.map_error(HashFailed)
}

pub fn verify(encoded_hash: String, candidate: String) -> Result(Bool, Error) {
  case is_bcrypt(encoded_hash) {
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
/// bridge and must be replaced with the current Argon2id policy after the
/// first valid login. Valid Argon2 hashes using an older policy are upgraded
/// through the same successful-login path.
pub fn needs_rehash(encoded_hash: String) -> Bool {
  case is_bcrypt(encoded_hash), is_argon2(encoded_hash) {
    True, _ -> True
    False, True -> !is_current_argon2id(encoded_hash)
    False, False -> False
  }
}

fn configured_hasher() -> argus.Hasher {
  argus.hasher()
  |> argus.algorithm(argus.Argon2id)
  |> argus.time_cost(argon2_time_cost)
  |> argus.memory_cost(argon2_memory_cost_kib)
  |> argus.parallelism(argon2_parallelism)
  |> argus.hash_length(argon2_hash_length)
}

fn is_bcrypt(encoded_hash: String) -> Bool {
  string.starts_with(encoded_hash, "$2a$")
  || string.starts_with(encoded_hash, "$2b$")
  || string.starts_with(encoded_hash, "$2y$")
}

fn is_argon2(encoded_hash: String) -> Bool {
  string.starts_with(encoded_hash, "$argon2d$")
  || string.starts_with(encoded_hash, "$argon2i$")
  || string.starts_with(encoded_hash, "$argon2id$")
}

fn is_current_argon2id(encoded_hash: String) -> Bool {
  case string.split(encoded_hash, "$") {
    ["", "argon2id", version, parameters, salt, hash] ->
      version == argon2_phc_version
      && parameters == argon2_phc_parameters
      && string.length(salt) == argon2_encoded_salt_length
      && string.length(hash) == argon2_encoded_hash_length
    _ -> False
  }
}

fn normalise_bcrypt(encoded_hash: String) -> String {
  case string.starts_with(encoded_hash, "$2y$") {
    True -> "$2a$" <> string.drop_start(encoded_hash, 4)
    False -> encoded_hash
  }
}
