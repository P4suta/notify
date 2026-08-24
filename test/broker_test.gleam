import gleam/erlang/process
import gleam/option
import notify/broker
import notify/core/filter
import notify/core/message
import notify/core/topic

fn fixture(id: String) -> message.Message {
  let assert Ok(topic) = topic.parse("alerts")
  message.Message(
    id:,
    time: 100,
    expires: option.None,
    event: message.MessageEvent,
    topic:,
    message: id,
    title: option.None,
    priority: message.Default,
    tags: [],
    markdown: False,
    icon: option.None,
    click: option.None,
    actions: [],
    attachment: option.None,
    scheduled: False,
    cached: True,
    sequence_id: option.None,
  )
}

pub fn ordered_delivery_is_replenished_by_credit_test() {
  let assert Ok(bus) = broker.start()
  let subject = process.new_subject()
  let assert Ok(alerts) = topic.parse("alerts")
  let subscription = bus.subscribe([alerts], subject, 1)

  bus.broadcast(fixture("B000000001"))
  let assert Ok(broker.Message(first)) = process.receive(subject, 1000)
  assert first.id == "B000000001"
  bus.ack(subscription)

  bus.broadcast(fixture("B000000002"))
  let assert Ok(broker.Message(second)) = process.receive(subject, 1000)
  assert second.id == "B000000002"
}

pub fn slow_subscriber_overflows_without_blocking_publisher_test() {
  let assert Ok(bus) = broker.start()
  let subject = process.new_subject()
  let assert Ok(alerts) = topic.parse("alerts")
  let _subscription = bus.subscribe([alerts], subject, 2)

  bus.broadcast(fixture("B000000003"))
  bus.broadcast(fixture("B000000004"))
  bus.broadcast(fixture("B000000005"))

  let assert Ok(broker.Message(first)) = process.receive(subject, 1000)
  let assert Ok(broker.Message(second)) = process.receive(subject, 1000)
  let assert Ok(broker.Overflow) = process.receive(subject, 1000)
  assert first.id == "B000000003"
  assert second.id == "B000000004"
}

pub fn only_matching_topics_are_fanned_out_test() {
  let assert Ok(bus) = broker.start()
  let subject = process.new_subject()
  let assert Ok(other) = topic.parse("other")
  let _subscription = bus.subscribe([other], subject, 1)

  bus.broadcast(fixture("B000000006"))
  assert process.receive(subject, 10) == Error(Nil)
}

pub fn live_filters_do_not_consume_subscriber_credit_test() {
  let assert Ok(bus) = broker.start()
  let subject = process.new_subject()
  let assert Ok(alerts) = topic.parse("alerts")
  let criteria =
    filter.Criteria(..filter.none(), priorities: [message.High], tags: ["ops"])
  let _subscription = bus.subscribe_filtered([alerts], criteria, subject, 1)

  bus.broadcast(fixture("ignored"))
  assert process.receive(subject, 10) == Error(Nil)

  bus.broadcast(
    message.Message(..fixture("matching"), priority: message.High, tags: [
      "ops",
      "production",
    ]),
  )
  let assert Ok(broker.Message(received)) = process.receive(subject, 1000)
  assert received.id == "matching"
  assert process.receive(subject, 10) == Error(Nil)
}

pub fn paused_subscription_replays_before_buffered_live_without_duplicates_test() {
  let assert Ok(bus) = broker.start()
  let subject = process.new_subject()
  let assert Ok(alerts) = topic.parse("alerts")
  let subscription = bus.subscribe_paused([alerts], subject, 3)
  let overlapping = fixture("B000000007")
  bus.broadcast(overlapping)

  process.send(subject, broker.Replay(overlapping))
  bus.activate(subscription, [overlapping.id], 1)
  let assert Ok(broker.Replay(replayed)) = process.receive(subject, 1000)
  assert replayed.id == overlapping.id
  assert process.receive(subject, 10) == Error(Nil)

  bus.broadcast(fixture("B000000008"))
  let assert Ok(broker.Message(live)) = process.receive(subject, 1000)
  assert live.id == "B000000008"
}

pub fn prepared_activation_rebinds_and_orders_replay_before_live_test() {
  let assert Ok(bus) = broker.start()
  let placeholder = process.new_subject()
  let stream = process.new_subject()
  let assert Ok(alerts) = topic.parse("alerts")
  let subscription = bus.subscribe_paused([alerts], placeholder, 3)
  let overlapping = fixture("B000000009XY")
  bus.broadcast(overlapping)

  bus.activate_prepared(
    subscription,
    stream,
    broker.Open("O000000001XY", 100, [alerts]),
    [overlapping],
  )

  let assert Ok(broker.Open(_, _, _)) = process.receive(stream, 1000)
  let assert Ok(broker.Replay(replayed)) = process.receive(stream, 1000)
  assert replayed.id == overlapping.id
  assert process.receive(stream, 10) == Error(Nil)
  assert process.receive(placeholder, 10) == Error(Nil)

  bus.broadcast(fixture("B000000010XY"))
  let assert Ok(broker.Message(live)) = process.receive(stream, 1000)
  assert live.id == "B000000010XY"
}
