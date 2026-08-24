import gleam/int
import gleam/result
import notify/delivery
import notify/delivery/worker
import notify/runtime
import notify/webpush
import notify/webpush/crypto

pub type Sender {
  Sender(
    fn(String, String, String, String, String, String, BitArray, Int, Int) ->
      Result(Int, String),
  )
}

pub fn production_sender() -> Sender {
  Sender(crypto.send)
}

pub fn new(
  configured: runtime.WebPushRuntime,
  sender: Sender,
  now: fn() -> Int,
) -> worker.Provider {
  worker.Provider(kind: delivery.WebPush, deliver: fn(job) {
    deliver(configured, sender, now, job)
  })
}

fn deliver(
  configured: runtime.WebPushRuntime,
  sender: Sender,
  now: fn() -> Int,
  job: delivery.Job,
) -> Result(Nil, String) {
  case job.kind {
    delivery.MobileRelay -> Error("invalid delivery kind for Web Push provider")
    delivery.WebPush ->
      case configured.store.by_endpoint(job.endpoint) {
        Error(webpush.NotFound) -> Ok(Nil)
        Error(error) -> Error(store_error(error))
        Ok(subscription) ->
          case webpush.endpoint_allowed(subscription.endpoint) {
            False -> remove_permanent(configured, subscription.endpoint)
            True -> {
              let Sender(send) = sender
              case
                send(
                  subscription.endpoint,
                  subscription.auth,
                  subscription.p256dh,
                  configured.public_key,
                  configured.private_key,
                  configured.subscriber,
                  job.payload,
                  43_200,
                  now(),
                )
              {
                Ok(status) if status >= 200 && status < 300 -> Ok(Nil)
                Ok(404) | Ok(410) ->
                  remove_permanent(configured, subscription.endpoint)
                Ok(status) if status >= 400 && status < 500 && status != 429 ->
                  remove_permanent(configured, subscription.endpoint)
                Ok(status) -> Error("Web Push HTTP " <> int.to_string(status))
                Error(detail) -> Error(detail)
              }
            }
          }
      }
  }
}

fn remove_permanent(
  configured: runtime.WebPushRuntime,
  endpoint: String,
) -> Result(Nil, String) {
  configured.store.remove_endpoint(endpoint)
  |> result.map_error(store_error)
}

fn store_error(error: webpush.Error) -> String {
  case error {
    webpush.InvalidSubscription -> "invalid Web Push subscription"
    webpush.UnknownEndpoint -> "unknown Web Push endpoint"
    webpush.TooManyTopics -> "too many Web Push topics"
    webpush.TooManySubscriptions -> "too many Web Push subscriptions"
    webpush.NotFound -> "Web Push subscription not found"
    webpush.Conflict -> "Web Push subscription conflict"
    webpush.Unavailable(detail) -> "Web Push store unavailable: " <> detail
  }
}
