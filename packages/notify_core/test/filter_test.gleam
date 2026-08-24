import gleam/option.{None, Some}
import notify/core/filter
import notify/core/message
import notify/core/topic

fn fixture() -> message.Message {
  let assert Ok(topic) = topic.parse("alerts")
  message.Message(
    id: "AbCdEf1234",
    time: 100,
    expires: Some(200),
    event: message.MessageEvent,
    topic: topic,
    message: "Disk full",
    title: Some("Storage"),
    priority: message.Max,
    tags: ["warning", "disk"],
    markdown: False,
    icon: None,
    click: None,
    actions: [],
    attachment: None,
    scheduled: False,
    cached: True,
    sequence_id: None,
  )
}

pub fn matches_all_configured_fields_test() {
  let criteria =
    filter.Criteria(
      id: Some("AbCdEf1234"),
      message: Some("Disk full"),
      title: Some("Storage"),
      priorities: [message.Max, message.High],
      tags: ["warning"],
    )
  assert filter.matches(fixture(), criteria)
}

pub fn rejects_when_any_field_differs_test() {
  let criteria =
    filter.Criteria(
      id: None,
      message: None,
      title: Some("Other"),
      priorities: [],
      tags: [],
    )
  assert !filter.matches(fixture(), criteria)
}

pub fn accepts_any_selected_priority_test() {
  let criteria =
    filter.Criteria(
      id: None,
      message: None,
      title: None,
      priorities: [message.Min, message.Max],
      tags: [],
    )
  assert filter.matches(fixture(), criteria)
}

pub fn empty_criteria_match_and_id_and_message_are_both_required_test() {
  assert filter.matches(fixture(), filter.none())
  let wrong_id =
    filter.Criteria(
      id: Some("WrongId000"),
      message: Some("Disk full"),
      title: None,
      priorities: [],
      tags: [],
    )
  assert !filter.matches(fixture(), wrong_id)
}
