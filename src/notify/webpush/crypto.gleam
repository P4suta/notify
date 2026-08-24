pub fn encrypt_with_values(
  plaintext: BitArray,
  auth auth: String,
  receiver_public receiver_public: String,
  sender_public sender_public: String,
  sender_private sender_private: String,
  salt salt: String,
) -> Result(BitArray, String) {
  encrypt_deterministic(
    plaintext,
    auth,
    receiver_public,
    sender_public,
    sender_private,
    salt,
  )
}

pub fn encrypt(
  plaintext: BitArray,
  auth auth: String,
  receiver_public receiver_public: String,
) -> Result(BitArray, String) {
  encrypt_random(plaintext, auth, receiver_public)
}

pub fn generate_keys() -> Result(#(String, String), String) {
  generate_vapid_keys()
}

pub fn vapid_authorization(
  endpoint: String,
  subscriber: String,
  public_key: String,
  private_key: String,
  now: Int,
) -> Result(String, String) {
  vapid_header(endpoint, subscriber, public_key, private_key, now)
}

pub fn verify_authorization(header: String, public_key: String) -> Bool {
  verify_vapid_header(header, public_key)
}

pub fn send(
  endpoint: String,
  auth: String,
  receiver_public: String,
  vapid_public: String,
  vapid_private: String,
  subscriber: String,
  plaintext: BitArray,
  ttl_seconds: Int,
  now: Int,
) -> Result(Int, String) {
  send_webpush(
    endpoint,
    auth,
    receiver_public,
    vapid_public,
    vapid_private,
    subscriber,
    plaintext,
    ttl_seconds,
    now,
  )
}

@external(erlang, "notify_ffi", "webpush_encrypt_with_values")
fn encrypt_deterministic(
  plaintext: BitArray,
  auth: String,
  receiver_public: String,
  sender_public: String,
  sender_private: String,
  salt: String,
) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "webpush_encrypt")
fn encrypt_random(
  plaintext: BitArray,
  auth: String,
  receiver_public: String,
) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "generate_vapid_keys")
fn generate_vapid_keys() -> Result(#(String, String), String)

@external(erlang, "notify_ffi", "webpush_vapid_header")
fn vapid_header(
  endpoint: String,
  subscriber: String,
  public_key: String,
  private_key: String,
  now: Int,
) -> Result(String, String)

@external(erlang, "notify_ffi", "webpush_verify_vapid_header")
fn verify_vapid_header(header: String, public_key: String) -> Bool

@external(erlang, "notify_ffi", "webpush_send")
fn send_webpush(
  endpoint: String,
  auth: String,
  receiver_public: String,
  vapid_public: String,
  vapid_private: String,
  subscriber: String,
  plaintext: BitArray,
  ttl_seconds: Int,
  now: Int,
) -> Result(Int, String)
