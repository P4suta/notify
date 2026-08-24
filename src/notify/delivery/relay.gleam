import gleam/bit_array
import gleam/int
import gleam/json
import notify/delivery
import notify/delivery/worker
import notify/security/token

pub type Sender {
  Sender(fn(String, String, String) -> Result(Int, String))
}

pub fn production_sender() -> Sender {
  Sender(send)
}

pub fn provider(token: String, sender: Sender) -> worker.Provider {
  worker.Provider(kind: delivery.MobileRelay, deliver: fn(job) {
    case job.kind {
      delivery.WebPush -> Error("invalid delivery kind for mobile relay")
      delivery.MobileRelay -> {
        let Sender(send_request) = sender
        case send_request(job.endpoint, token, job.message_id) {
          Ok(200) -> Ok(Nil)
          Ok(status) -> Error("mobile relay HTTP " <> int.to_string(status))
          Error(detail) -> Error(detail)
        }
      }
    }
  })
}

/// The upstream mobile relay is deliberately content-blind. Only the message
/// identifier and a one-way hash of the canonical topic URL leave the server.
pub fn payload(
  message_id message_id: String,
  topic_url topic_url: String,
) -> BitArray {
  json.object([
    #("message_id", json.string(message_id)),
    #("topic_url_hash", json.string(token.digest(topic_url))),
  ])
  |> json.to_string
  |> bit_array.from_string
}

@external(erlang, "notify_ffi", "relay_send")
fn send(endpoint: String, token: String, poll_id: String) -> Result(Int, String)
