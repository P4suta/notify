import gleam/int
import gleam/json
import gleam/option.{None}
import notify/core/acl
import notify/core/delay
import notify/core/message
import notify/core/message_json
import notify/core/topic
import qcheck

const property_cases = 500

fn deterministic_config(seed: Int) -> qcheck.Config {
  qcheck.config(
    test_count: property_cases,
    max_retries: 1,
    seed: qcheck.seed(seed),
  )
}

fn valid_topic_generator() -> qcheck.Generator(String) {
  use length <- qcheck.then(qcheck.bounded_int(1, 64))
  qcheck.fixed_length_string_from(qcheck.alphanumeric_ascii_codepoint(), length)
}

pub fn valid_topics_round_trip_property_test() {
  qcheck.run(deterministic_config(10_001), valid_topic_generator(), fn(name) {
    let assert Ok(parsed) = topic.parse(name)
    assert topic.to_string(parsed) == name
  })
}

pub fn priorities_round_trip_property_test() {
  qcheck.run(deterministic_config(10_002), qcheck.bounded_int(1, 5), fn(value) {
    let assert Ok(priority) = message.priority_from_int(value)
    assert message.priority_to_int(priority) == value
  })
}

pub fn relative_seconds_resolve_from_now_property_test() {
  qcheck.run(
    deterministic_config(10_003),
    qcheck.bounded_int(1, 86_400),
    fn(seconds) {
      let encoded = int.to_string(seconds) <> "s"
      assert delay.resolve(encoded, now: 1_725_000_000)
        == Ok(1_725_000_000 + seconds)
    },
  )
}

pub fn message_json_round_trip_property_test() {
  let generator =
    qcheck.map2(
      valid_topic_generator(),
      qcheck.non_empty_string_from(qcheck.printable_ascii_codepoint()),
      fn(topic_name, body) { #(topic_name, body) },
    )
  qcheck.run(deterministic_config(10_004), generator, fn(input) {
    let #(topic_name, body) = input
    let assert Ok(parsed_topic) = topic.parse(topic_name)
    let original =
      message.Message(
        id: "AbCdEf1234XY",
        time: 1_725_000_000,
        expires: None,
        event: message.MessageEvent,
        topic: parsed_topic,
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
    let encoded = original |> message_json.encode_storage |> json.to_string
    let assert Ok(decoded) = json.parse(encoded, message_json.decoder())
    assert decoded == original
  })
}

pub fn wildcard_prefix_matches_every_generated_suffix_property_test() {
  qcheck.run(
    deterministic_config(10_005),
    qcheck.string_from(qcheck.alphanumeric_ascii_codepoint()),
    fn(suffix) {
      assert acl.pattern_matches("alerts-*", "alerts-" <> suffix)
    },
  )
}
