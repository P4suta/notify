import gleam/erlang/process
import gleam/option.{None}
import notify/broker
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/http/subscription

fn fixture(body: String) -> message.Message {
  let assert Ok(alerts) = topic.parse("alerts")
  message.Message(
    id: "S000000001XY",
    time: 100,
    expires: None,
    event: message.MessageEvent,
    topic: alerts,
    message: body,
    title: None,
    priority: message.Default,
    tags: [],
    markdown: False,
    icon: None,
    click: None,
    actions: [],
    attachment: None,
    scheduled: False,
    cached: True,
    sequence_id: None,
    poll_id: None,
  )
}

pub fn prepared_subscription_payloads_preserve_all_wire_bytes_test() {
  let notification = fixture("one\ntwo\rthree")
  let structured =
    broker.prepare_message(notification, broker.Structured)
    |> broker.Message
  let raw = broker.prepare_message(notification, broker.Raw) |> broker.Message

  assert subscription.payload(structured, subscription.WebSocket)
    == <<
      "{\"id\":\"S000000001XY\",\"time\":100,\"event\":\"message\",\"topic\":\"alerts\",\"message\":\"one\\ntwo\\rthree\"}":utf8,
    >>
  assert subscription.payload(structured, subscription.Json)
    == <<
      "{\"id\":\"S000000001XY\",\"time\":100,\"event\":\"message\",\"topic\":\"alerts\",\"message\":\"one\\ntwo\\rthree\"}\n":utf8,
    >>
  assert subscription.payload(structured, subscription.Sse)
    == <<
      "data: {\"id\":\"S000000001XY\",\"time\":100,\"event\":\"message\",\"topic\":\"alerts\",\"message\":\"one\\ntwo\\rthree\"}\n\n":utf8,
    >>
  assert subscription.payload(raw, subscription.Raw)
    == <<"one two three\n":utf8>>
}

pub fn control_and_overflow_framing_is_transport_stable_test() {
  let assert Ok(alerts) = topic.parse("alerts")
  let opening = broker.Open("O000000001XY", 100, [alerts])
  assert subscription.payload(opening, subscription.Json)
    == <<
      "{\"id\":\"O000000001XY\",\"time\":100,\"event\":\"open\",\"topic\":\"alerts\"}\n":utf8,
    >>
  assert subscription.payload(opening, subscription.Sse)
    == <<
      "event: open\ndata: {\"id\":\"O000000001XY\",\"time\":100,\"event\":\"open\",\"topic\":\"alerts\"}\n\n":utf8,
    >>
  assert subscription.payload(broker.Overflow, subscription.WebSocket)
    == <<
      "{\"code\":42909,\"http\":429,\"error\":\"slow subscriber buffer exhausted\"}":utf8,
    >>
  assert subscription.payload(broker.Overflow, subscription.Raw)
    == <<"\n":utf8>>
}

pub fn broker_selects_structured_and_raw_representation_per_subscriber_test() {
  let assert Ok(bus) = broker.start()
  let assert Ok(alerts) = topic.parse("alerts")
  let structured = process.new_subject()
  let raw = process.new_subject()
  let structured_id =
    bus.subscribe_paused_filtered_as(
      [alerts],
      filter.none(),
      broker.Structured,
      structured,
      2,
    )
  let raw_id =
    bus.subscribe_paused_filtered_as(
      [alerts],
      filter.none(),
      broker.Raw,
      raw,
      2,
    )
  bus.activate_prepared(
    structured_id,
    structured,
    broker.Open("O000000001XY", 100, [alerts]),
    [],
  )
  bus.activate_prepared(
    raw_id,
    raw,
    broker.Open("O000000002XY", 100, [alerts]),
    [],
  )
  let assert Ok(broker.Open(..)) = process.receive(structured, 1000)
  let assert Ok(broker.Open(..)) = process.receive(raw, 1000)

  bus.dispatch(fixture("line\nbreak"))
  let assert Ok(broker.Message(broker.PreparedMessage(_, structured_payload))) =
    process.receive(structured, 1000)
  let assert Ok(broker.Message(broker.PreparedMessage(_, raw_payload))) =
    process.receive(raw, 1000)
  assert structured_payload
    == <<
      "{\"id\":\"S000000001XY\",\"time\":100,\"event\":\"message\",\"topic\":\"alerts\",\"message\":\"line\\nbreak\"}":utf8,
    >>
  assert raw_payload == <<"line break\n":utf8>>
}
