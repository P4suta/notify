import gleam/bit_array
import gleam/string
import notify/webpush/crypto

pub fn rfc8291_encryption_vector_test() {
  let plaintext = "When I grow up, I want to be a watermelon"
  let assert Ok(body) =
    crypto.encrypt_with_values(
      bit_array.from_string(plaintext),
      auth: "BTBZMqHH6r4Tts7J_aSIgg",
      receiver_public: "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
      sender_public: "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8",
      sender_private: "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw",
      salt: "DGv6ra1nlYgDCS1FRnbzlw",
    )
  assert bit_array.base64_url_encode(body, False)
    == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
}

pub fn vapid_authorization_is_an_es256_jwt_bound_to_origin_test() {
  let assert Ok(#(public, private)) = crypto.generate_keys()
  let assert Ok(authorization) =
    crypto.vapid_authorization(
      "https://fcm.googleapis.com/fcm/send/browser-token",
      "admin@example.test",
      public,
      private,
      1_725_000_000,
    )
  assert string.starts_with(authorization, "vapid t=")
  assert string.contains(authorization, ", k=" <> public)
  assert crypto.verify_authorization(authorization, public)
}
