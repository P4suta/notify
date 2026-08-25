import gleam/json
import gleam/option.{None, Some}
import gleam/string
import notify/core/message
import notify/core/message_json
import notify/core/topic

fn fixture_message() -> message.Message {
  let assert Ok(topic) = topic.parse("backups")
  message.Message(
    id: "AbCdEf1234XY",
    time: 1_725_000_000,
    expires: Some(1_725_043_200),
    event: message.MessageEvent,
    topic: topic,
    message: "Backup complete",
    title: Some("Nightly"),
    priority: message.High,
    tags: ["white_check_mark", "backup"],
    markdown: True,
    icon: None,
    click: Some("https://example.test/backups/42"),
    actions: [],
    attachment: None,
    scheduled: False,
    cached: True,
    sequence_id: Some("backup-42"),
  )
}

pub fn encodes_ntfy_message_without_null_fields_test() {
  let encoded = fixture_message() |> message_json.encode |> json.to_string
  assert encoded
    == "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"expires\":1725043200,\"event\":\"message\",\"topic\":\"backups\",\"message\":\"Backup complete\",\"title\":\"Nightly\",\"priority\":4,\"tags\":[\"white_check_mark\",\"backup\"],\"content_type\":\"text/markdown\",\"click\":\"https://example.test/backups/42\",\"sequence_id\":\"backup-42\"}"
}

pub fn decodes_current_content_type_and_legacy_markdown_wire_fields_test() {
  let current =
    "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"event\":\"message\",\"topic\":\"backups\",\"message\":\"ok\",\"content_type\":\"text/markdown\"}"
  let legacy =
    "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"event\":\"message\",\"topic\":\"backups\",\"message\":\"ok\",\"markdown\":true}"
  let assert Ok(current_message) = json.parse(current, message_json.decoder())
  let assert Ok(legacy_message) = json.parse(legacy, message_json.decoder())
  assert current_message.markdown
  assert legacy_message.markdown
}

pub fn decodes_json_publish_with_ntfy_defaults_test() {
  let body = "{\"topic\":\"backups\",\"message\":\"Backup complete\"}"
  let assert Ok(draft) = message_json.decode_publish(body)
  assert draft.topic == fixture_message().topic
  assert draft.message == "Backup complete"
  assert draft.priority == message.Default
  assert draft.title == None
  assert draft.tags == []
  assert !draft.markdown
  assert draft.icon == None
  assert draft.click == None
  assert draft.actions == []
  assert draft.attachment == None
  assert draft.delay == None
  assert draft.sequence_id == None
  assert draft.cache
}

pub fn defaults_missing_json_message_to_triggered_test() {
  let assert Ok(draft) = message_json.decode_publish("{\"topic\":\"backups\"}")
  assert draft.message == "triggered"
}

pub fn rejects_invalid_topic_or_priority_in_json_test() {
  assert message_json.decode_publish("{") == Error(message_json.MalformedJson)
  assert message_json.decode_publish("{}") == Error(message_json.InvalidJson)
  let assert Error(message_json.InvalidTopic(_)) =
    message_json.decode_publish("{\"topic\":\"bad/topic\",\"message\":\"x\"}")
  let assert Error(message_json.InvalidPriority(7)) =
    message_json.decode_publish(
      "{\"topic\":\"backups\",\"message\":\"x\",\"priority\":7}",
    )
  let assert Error(message_json.InvalidPriority(0)) =
    message_json.decode_publish(
      "{\"topic\":\"backups\",\"message\":\"x\",\"priority\":\"bogus\"}",
    )
}

pub fn encodes_multi_topic_open_control_event_test() {
  let assert Ok(one) = topic.parse("one")
  let assert Ok(two) = topic.parse("two")
  let encoded =
    message_json.encode_control(
      id: "AbCdEf1234XY",
      time: 1_725_000_000,
      event: message.OpenEvent,
      topics: [one, two],
    )
    |> json.to_string
  assert encoded
    == "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"event\":\"open\",\"topic\":\"one,two\"}"
}

pub fn stored_message_round_trips_actions_and_attachment_test() {
  let original =
    message.Message(
      ..fixture_message(),
      actions: [
        message.ViewAction(
          label: "Open",
          url: "https://example.test/42",
          clear: True,
          id: None,
        ),
        message.HttpAction(
          label: "Acknowledge",
          url: "https://example.test/42/ack",
          method: "PUT",
          headers: [#("authorization", "Bearer test")],
          body: Some("{\"ok\":true}"),
          clear: False,
          id: Some("ActionHttp01"),
        ),
        message.CopyAction(
          label: "Copy",
          value: "incident-42",
          clear: False,
          id: None,
        ),
      ],
      attachment: Some(message.Attachment(
        name: "report.pdf",
        url: "https://example.test/report.pdf",
        mime_type: Some("application/pdf"),
        size: Some(4096),
        expires: Some(1_725_043_200),
      )),
    )

  let encoded = original |> message_json.encode |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, message_json.decoder())
  assert decoded == original
}

pub fn json_publish_decodes_structured_actions_test() {
  let body =
    "{\"topic\":\"backups\",\"message\":\"Done\",\"actions\":[{\"action\":\"view\",\"label\":\"Open\",\"url\":\"https://example.test\",\"clear\":true},{\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"42\"}]}"
  let assert Ok(draft) = message_json.decode_publish(body)
  assert draft.actions
    == [
      message.ViewAction(
        label: "Open",
        url: "https://example.test",
        clear: True,
        id: None,
      ),
      message.CopyAction(label: "Copy", value: "42", clear: False, id: None),
    ]
}

pub fn storage_codec_preserves_private_delivery_flags_and_icon_test() {
  let original =
    message.Message(
      ..fixture_message(),
      icon: Some("https://example.test/icon.png"),
      scheduled: True,
      cached: False,
    )
  let encoded = original |> message_json.encode_storage |> json.to_string
  assert string.contains(encoded, "\"icon\":\"https://example.test/icon.png\"")
  assert string.contains(encoded, "\"_notify_scheduled\":true")
  assert string.contains(encoded, "\"_notify_cached\":false")
  let assert Ok(decoded) = json.parse(encoded, message_json.decoder())
  assert decoded == original
}

pub fn message_decoder_defaults_are_explicit_and_content_type_is_exact_test() {
  let minimal =
    "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"event\":\"open\",\"topic\":\"backups\"}"
  let assert Ok(decoded) = json.parse(minimal, message_json.decoder())
  assert decoded.message == ""
  assert !decoded.markdown
  assert !decoded.scheduled
  assert decoded.cached
  assert decoded.icon == None

  let other_content =
    "{\"id\":\"AbCdEf1234XY\",\"time\":1725000000,\"event\":\"message\",\"topic\":\"backups\",\"message\":\"ok\",\"content_type\":\"application/json\",\"icon\":\"https://example.test/icon.png\"}"
  let assert Ok(other) = json.parse(other_content, message_json.decoder())
  assert !other.markdown
  assert other.icon == Some("https://example.test/icon.png")
}

pub fn action_json_defaults_and_clear_fields_round_trip_exactly_test() {
  let body =
    "[{\"action\":\"view\",\"label\":\"Open\",\"url\":\"https://example.test\"},{\"action\":\"http\",\"label\":\"Send\",\"url\":\"https://api.example.test\"},{\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"42\",\"clear\":true}]"
  let assert Ok(actions) = message_json.decode_actions(body)
  assert actions
    == [
      message.ViewAction(
        label: "Open",
        url: "https://example.test",
        clear: False,
        id: None,
      ),
      message.HttpAction(
        label: "Send",
        url: "https://api.example.test",
        method: "POST",
        headers: [],
        body: None,
        clear: False,
        id: None,
      ),
      message.CopyAction(label: "Copy", value: "42", clear: True, id: None),
    ]

  let with_clear =
    message.Message(..fixture_message(), actions: [
      message.HttpAction(
        label: "Send",
        url: "https://api.example.test",
        method: "POST",
        headers: [],
        body: None,
        clear: True,
        id: None,
      ),
      message.CopyAction(label: "Copy", value: "42", clear: True, id: None),
    ])
  let encoded = with_clear |> message_json.encode |> json.to_string
  let assert Ok(round_trip) = json.parse(encoded, message_json.decoder())
  assert round_trip == with_clear
}

pub fn full_json_publish_maps_every_optional_field_test() {
  let body =
    "{\"topic\":\"backups\",\"message\":\"Done\",\"title\":\"Nightly\",\"tags\":[\"backup\",\"ok\"],\"priority\":\"high\",\"markdown\":true,\"icon\":\"https://example.test/icon.png\",\"click\":\"https://example.test/jobs/42\",\"attach\":\"https://example.test/report.pdf\",\"filename\":\"report.pdf\",\"actions\":[{\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"42\"}],\"delay\":\"10m\",\"sequence_id\":\"nightly-42\",\"cache\":false}"
  let assert Ok(draft) = message_json.decode_publish(body)
  assert draft.message == "Done"
  assert draft.title == Some("Nightly")
  assert draft.tags == ["backup", "ok"]
  assert draft.priority == message.High
  assert draft.markdown
  assert draft.icon == Some("https://example.test/icon.png")
  assert draft.click == Some("https://example.test/jobs/42")
  assert draft.actions
    == [message.CopyAction(label: "Copy", value: "42", clear: False, id: None)]
  assert draft.delay == Some("10m")
  assert draft.sequence_id == Some("nightly-42")
  assert !draft.cache
  assert draft.attachment
    == Some(message.Attachment(
      name: "report.pdf",
      url: "https://example.test/report.pdf",
      mime_type: None,
      size: None,
      expires: None,
    ))
}

pub fn remote_attachment_without_filename_uses_compatible_default_test() {
  let assert Ok(draft) =
    message_json.decode_publish(
      "{\"topic\":\"backups\",\"attach\":\"https://example.test/file\"}",
    )
  assert draft.attachment
    == Some(message.Attachment(
      name: "attachment",
      url: "https://example.test/file",
      mime_type: None,
      size: None,
      expires: None,
    ))
}

pub fn decoder_failures_name_the_invalid_wire_contract_test() {
  let invalid_topic =
    json.parse(
      "{\"id\":\"AbCdEf1234XY\",\"time\":1,\"event\":\"message\",\"topic\":\"bad/topic\"}",
      message_json.decoder(),
    )
    |> string.inspect
  assert string.contains(invalid_topic, "ntfy topic")

  let invalid_priority =
    json.parse(
      "{\"id\":\"AbCdEf1234XY\",\"time\":1,\"event\":\"message\",\"topic\":\"backups\",\"priority\":9}",
      message_json.decoder(),
    )
    |> string.inspect
  assert string.contains(invalid_priority, "priority 1 through 5")

  let invalid_event =
    json.parse(
      "{\"id\":\"AbCdEf1234XY\",\"time\":1,\"event\":\"unknown\",\"topic\":\"backups\"}",
      message_json.decoder(),
    )
    |> string.inspect
  assert string.contains(invalid_event, "ntfy event")

  let invalid_action =
    json.parse(
      "{\"id\":\"AbCdEf1234XY\",\"time\":1,\"event\":\"message\",\"topic\":\"backups\",\"actions\":[{\"action\":\"unknown\"}]}",
      message_json.decoder(),
    )
    |> string.inspect
  assert string.contains(invalid_action, "view, http, or copy action")
}
