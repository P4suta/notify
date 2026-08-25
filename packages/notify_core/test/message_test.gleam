import gleam/option.{None, Some}
import gleam/string
import notify/core/message
import notify/core/topic

fn fixture_topic() -> topic.Topic {
  let assert Ok(value) = topic.parse("backups")
  value
}

pub fn builds_a_deterministic_plaintext_message_test() {
  let draft = message.plaintext_draft(fixture_topic(), "Backup complete")
  assert !draft.markdown
  assert draft.cache
  let assert Ok(value) =
    message.materialise(
      draft,
      id: "AbCdEf1234XY",
      now: 1_725_000_000,
      expires: 1_725_043_200,
    )

  assert value.id == "AbCdEf1234XY"
  assert value.topic == fixture_topic()
  assert value.message == "Backup complete"
  assert value.title == None
  assert value.priority == message.Default
  assert value.tags == []
  assert value.time == 1_725_000_000
  assert value.expires == Some(1_725_043_200)
  assert !value.scheduled
  assert value.cached
}

pub fn validates_id_message_and_priority_test() {
  let draft = message.plaintext_draft(fixture_topic(), "")
  let assert Error(message.EmptyMessage) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 1, expires: 2)

  let draft = message.plaintext_draft(fixture_topic(), "ok")
  let assert Error(message.InvalidId) =
    message.materialise(draft, id: "short", now: 1, expires: 2)

  let assert Error(message.InvalidExpiry) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 2, expires: 2)

  let assert Error(message.InvalidPriority(9)) = message.priority_from_int(9)
}

pub fn message_ids_are_exactly_twelve_ascii_alphanumerics_test() {
  assert message.valid_id("AbCdEf1234XY")
  assert !message.valid_id("AbCdEf1234X")
  assert !message.valid_id("AbCdEf1234XYZ")
  assert !message.valid_id("AbCdEf1234-_")
}

pub fn sequence_ids_use_the_pinned_ntfy_charset_and_length_test() {
  let sixty_four =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
  assert message.valid_sequence_id("a")
  assert message.valid_sequence_id("job_42-nightly")
  assert message.valid_sequence_id(sixty_four)
  assert !message.valid_sequence_id("")
  assert !message.valid_sequence_id(sixty_four <> "a")
  assert !message.valid_sequence_id("invalid*sequence")
  assert !message.valid_sequence_id("invalid.sequence")
  assert !message.valid_sequence_id("ジョブ42")
}

pub fn materialise_rejects_invalid_sequence_parameters_test() {
  let invalid =
    message.Draft(
      ..message.plaintext_draft(fixture_topic(), "Backup complete"),
      sequence_id: Some("invalid*sequence"),
      poll_id: None,
    )
  let assert Error(message.InvalidSequenceId) =
    message.materialise(invalid, id: "AbCdEf1234XY", now: 1, expires: 2)
}

pub fn poll_request_materialisation_uses_the_pinned_ntfy_shape_test() {
  let draft =
    message.Draft(
      ..message.plaintext_draft(fixture_topic(), "ignored by poll requests"),
      title: Some("Ignored title"),
      priority: message.Max,
      tags: ["ignored"],
      markdown: True,
      icon: Some("https://example.test/icon.png"),
      click: Some("https://example.test/click"),
      actions: [
        message.CopyAction(
          label: "Ignored action",
          value: "ignored",
          clear: True,
          id: None,
        ),
      ],
      attachment: Some(message.Attachment(
        name: "ignored.txt",
        url: "https://example.test/ignored.txt",
        mime_type: Some("text/plain"),
        size: Some(7),
        expires: Some(200),
      )),
      sequence_id: Some("sequence-42"),
      poll_id: Some("poll-request-42"),
      cache: True,
    )
  let assert Ok(value) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 100, expires: 200)

  assert value.event == message.PollRequestEvent
  assert value.message == "New message"
  assert value.expires == None
  assert !value.cached
  assert value.title == None
  assert value.priority == message.Default
  assert value.tags == []
  assert !value.markdown
  assert value.icon == None
  assert value.click == None
  assert value.actions == []
  assert value.attachment == None
  assert value.sequence_id == Some("sequence-42")
  assert value.poll_id == Some("poll-request-42")
}

pub fn message_body_is_limited_to_four_kibibytes_test() {
  let draft =
    message.plaintext_draft(fixture_topic(), string.repeat("a", times: 4096))
  let assert Ok(_) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 1, expires: 2)

  let too_large =
    message.plaintext_draft(fixture_topic(), string.repeat("a", times: 4097))
  let assert Error(message.MessageTooLarge(4096, 4097)) =
    message.materialise(too_large, id: "AbCdEf1234XY", now: 1, expires: 2)
}

pub fn message_body_limit_is_measured_in_utf8_bytes_test() {
  let draft =
    message.plaintext_draft(fixture_topic(), string.repeat("界", times: 1366))
  let assert Error(message.MessageTooLarge(4096, 4098)) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 1, expires: 2)
}

pub fn materialise_assigns_stable_ten_character_action_ids_test() {
  let draft =
    message.Draft(
      ..message.plaintext_draft(fixture_topic(), "Act now"),
      actions: [
        message.ViewAction(
          label: "Open",
          url: "https://example.test",
          clear: False,
          id: None,
        ),
        message.CopyAction(label: "Copy", value: "42", clear: False, id: None),
      ],
    )
  let assert Ok(value) =
    message.materialise(draft, id: "AbCdEf1234XY", now: 1, expires: 2)
  let assert [
    message.ViewAction(id: Some(first), ..),
    message.CopyAction(id: Some(second), ..),
  ] = value.actions
  assert first == "AbCdEf12AA"
  assert second == "AbCdEf12AB"
  assert string.length(first) == 10
  assert string.length(second) == 10
}

pub fn parses_priority_names_and_numbers_test() {
  assert message.parse_priority("min") == Ok(message.Min)
  assert message.parse_priority("low") == Ok(message.Low)
  assert message.parse_priority("default") == Ok(message.Default)
  assert message.parse_priority("high") == Ok(message.High)
  assert message.parse_priority("urgent") == Ok(message.Max)
  assert message.parse_priority("5") == Ok(message.Max)
  assert message.parse_priority("not-a-priority")
    == Error(message.InvalidPriority(0))
}

pub fn priority_integer_mapping_is_bidirectional_for_every_value_test() {
  assert message.priority_from_int(1) == Ok(message.Min)
  assert message.priority_from_int(2) == Ok(message.Low)
  assert message.priority_from_int(3) == Ok(message.Default)
  assert message.priority_from_int(4) == Ok(message.High)
  assert message.priority_from_int(5) == Ok(message.Max)
  assert message.priority_to_int(message.Min) == 1
  assert message.priority_to_int(message.Low) == 2
  assert message.priority_to_int(message.Default) == 3
  assert message.priority_to_int(message.High) == 4
  assert message.priority_to_int(message.Max) == 5
}

pub fn control_messages_validate_sequence_boundaries_and_reset_payload_test() {
  let assert Ok(clear) =
    message.materialise_control(
      fixture_topic(),
      message.MessageClearEvent,
      "sequence-1",
      "AbCdEf1234XY",
      100,
    )
  assert clear.event == message.MessageClearEvent
  assert clear.message == ""
  assert clear.expires == None
  assert clear.title == None
  assert clear.priority == message.Default
  assert clear.tags == []
  assert !clear.markdown
  assert !clear.scheduled
  assert clear.cached
  assert clear.sequence_id == Some("sequence-1")

  let sixty_four =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let assert Ok(_) =
    message.materialise_control(
      fixture_topic(),
      message.MessageDeleteEvent,
      "a",
      "AbCdEf1234XY",
      100,
    )
  let assert Ok(_) =
    message.materialise_control(
      fixture_topic(),
      message.MessageDeleteEvent,
      sixty_four,
      "AbCdEf1234XY",
      100,
    )
  let assert Error(message.InvalidSequenceId) =
    message.materialise_control(
      fixture_topic(),
      message.MessageDeleteEvent,
      "",
      "AbCdEf1234XY",
      100,
    )
  let assert Error(message.InvalidSequenceId) =
    message.materialise_control(
      fixture_topic(),
      message.MessageDeleteEvent,
      sixty_four <> "a",
      "AbCdEf1234XY",
      100,
    )
  let assert Error(message.InvalidId) =
    message.materialise_control(
      fixture_topic(),
      message.MessageDeleteEvent,
      "sequence-1",
      "short",
      100,
    )
  let assert Error(message.InvalidSequenceId) =
    message.materialise_control(
      fixture_topic(),
      message.MessageEvent,
      "sequence-1",
      "AbCdEf1234XY",
      100,
    )
}

pub fn every_event_has_its_exact_wire_name_test() {
  assert message.event_to_string(message.OpenEvent) == "open"
  assert message.event_to_string(message.KeepaliveEvent) == "keepalive"
  assert message.event_to_string(message.MessageEvent) == "message"
  assert message.event_to_string(message.MessageDeleteEvent) == "message_delete"
  assert message.event_to_string(message.MessageClearEvent) == "message_clear"
  assert message.event_to_string(message.PollRequestEvent) == "poll_request"
}
