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

fn result_to_string(value: Result(BitArray, Nil)) -> Result(String, Nil) {
  case value {
    Error(error) -> Error(error)
    Ok(bytes) -> bit_array.to_string(bytes)
  }
}
