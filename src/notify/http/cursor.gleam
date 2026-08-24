import gleam/bit_array
import gleam/int
import gleam/string

pub type Error {
  InvalidCursor
}

pub fn encode(resource: String, position: Int) -> String {
  let payload = "v1:" <> resource <> ":" <> int.to_string(position)
  payload
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

pub fn decode(encoded: String, resource: String) -> Result(Int, Error) {
  case
    encoded
    |> bit_array.base64_url_decode
    |> result_to_string
  {
    Error(_) -> Error(InvalidCursor)
    Ok(payload) ->
      case string.split(payload, ":") {
        ["v1", found_resource, raw_position] if found_resource == resource ->
          case int.parse(raw_position) {
            Ok(position) if position > 0 ->
              case encode(resource, position) == encoded {
                True -> Ok(position)
                False -> Error(InvalidCursor)
              }
            _ -> Error(InvalidCursor)
          }
        _ -> Error(InvalidCursor)
      }
  }
}

pub fn encode_key(resource: String, key: String) -> String {
  let payload = "v1k:" <> encode_segment(resource) <> ":" <> encode_segment(key)
  encode_segment(payload)
}

pub fn decode_key(encoded: String, resource: String) -> Result(String, Error) {
  case string.length(encoded) >= 1 && string.length(encoded) <= 512 {
    False -> Error(InvalidCursor)
    True -> decode_key_payload(encoded, resource)
  }
}

fn decode_key_payload(
  encoded: String,
  resource: String,
) -> Result(String, Error) {
  case decode_segment(encoded) {
    Error(_) -> Error(InvalidCursor)
    Ok(payload) ->
      case string.split(payload, ":") {
        ["v1k", encoded_resource, encoded_key] ->
          case decode_segment(encoded_resource), decode_segment(encoded_key) {
            Ok(found_resource), Ok(key)
              if found_resource == resource && key != ""
            ->
              case encode_key(resource, key) == encoded {
                True -> Ok(key)
                False -> Error(InvalidCursor)
              }
            _, _ -> Error(InvalidCursor)
          }
        _ -> Error(InvalidCursor)
      }
  }
}

fn encode_segment(value: String) -> String {
  value
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

fn decode_segment(value: String) -> Result(String, Nil) {
  value
  |> bit_array.base64_url_decode
  |> result_to_string
}

fn result_to_string(value: Result(BitArray, Nil)) -> Result(String, Nil) {
  case value {
    Error(error) -> Error(error)
    Ok(bytes) -> bit_array.to_string(bytes)
  }
}
