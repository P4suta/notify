import gleam/list
import gleam/option.{None, Some}
import notify/webpush
import notify/webpush/memory
import notify/webpush/sqlite

fn subscription(
  id: String,
  endpoint: String,
  topics: List(String),
  now: Int,
) -> webpush.NewSubscription {
  webpush.NewSubscription(
    id:,
    endpoint:,
    auth: "kSC3T8aN1JCQxxPdrFLrZg",
    p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
    topics:,
    user_id: None,
    subscriber_ip: "192.0.2.1",
    now:,
  )
}

fn contract(store: webpush.Store) {
  let endpoint =
    "https://updates.push.services.mozilla.com/wpush/v2/browser-token"
  let assert Ok(first) =
    store.upsert(subscription("wps_first", endpoint, ["alerts", "ops"], 100))
  assert first.id == "wps_first"
  assert first.topics == ["alerts", "ops"]

  let assert Ok([for_alerts]) = store.for_topic("alerts")
  assert for_alerts.endpoint == endpoint

  let replacement =
    webpush.NewSubscription(
      ..subscription("wps_ignored", endpoint, ["ops"], 200),
      auth: "BTBZMqHH6r4Tts7J_aSIgg",
      user_id: Some("u_alice"),
    )
  let assert Ok(updated) = store.upsert(replacement)
  assert updated.id == "wps_first"
  assert updated.auth == "BTBZMqHH6r4Tts7J_aSIgg"
  assert updated.user_id == Some("u_alice")
  assert store.for_topic("alerts") == Ok([])
  let assert Ok([for_ops]) = store.for_topic("ops")
  assert for_ops.updated_at == 200

  assert store.remove_endpoint(endpoint) == Ok(Nil)
  assert store.for_topic("ops") == Ok([])
  assert store.health() == Ok(Nil)
}

pub fn memory_webpush_store_contract_test() {
  let assert Ok(store) = memory.start(max_endpoints_per_ip: 10)
  contract(store)
}

pub fn sqlite_webpush_store_contract_test() {
  let assert Ok(store) = sqlite.start(":memory:", max_endpoints_per_ip: 10)
  contract(store)
}

pub fn endpoint_allowlist_matches_ntfy_v2_27_security_boundary_test() {
  let allowed = [
    "https://fcm.googleapis.com/fcm/send/token",
    "https://jmt17.google.com/fcm/send/token",
    "https://updates.push.services.mozilla.com/wpush/v2/token",
    "https://autopush.mozaws.net/wpush/v1/token",
    "https://web.push.apple.com/token",
    "https://wns2-par02p.notify.windows.com/w/?token=value",
  ]
  let denied = [
    "http://fcm.googleapis.com/fcm/send/token",
    "https://attacker.example.com/fcm.googleapis.com/fcm/send/token",
    "https://fcm.googleapis.com.attacker.test/token",
    "https://fcm.googleapis.com@attacker.test/token",
    "https://notify.windows.com/token",
    "https://api.push.apple.com/token",
  ]
  assert list.all(allowed, webpush.endpoint_allowed)
  assert list.all(denied, fn(endpoint) { !webpush.endpoint_allowed(endpoint) })
}

pub fn subscription_validation_and_per_ip_quota_test() {
  let endpoint = "https://fcm.googleapis.com/fcm/send/token-one"
  assert webpush.validate(subscription("wps_one", endpoint, ["alerts"], 100))
    == Ok(Nil)
  assert webpush.validate(subscription("wps_one", endpoint, [], 100)) == Ok(Nil)
  let fifty_one = list.repeat("alerts", times: 51)
  assert webpush.validate(subscription("wps_one", endpoint, fifty_one, 100))
    == Error(webpush.TooManyTopics)

  let assert Ok(store) = memory.start(max_endpoints_per_ip: 1)
  let assert Ok(_) =
    store.upsert(subscription("wps_one", endpoint, ["alerts"], 100))
  assert store.upsert(subscription(
      "wps_two",
      "https://fcm.googleapis.com/fcm/send/token-two",
      ["alerts"],
      101,
    ))
    == Error(webpush.TooManySubscriptions)
}
