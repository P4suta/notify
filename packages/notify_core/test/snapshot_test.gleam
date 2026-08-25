import birdie
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import notify/core/action
import notify/core/message
import notify/core/message_json
import notify/core/topic

pub fn complete_ntfy_message_wire_snapshot_test() {
  let assert Ok(alerts) = topic.parse("alerts")
  message.Message(
    id: "AbCdEf1234XY",
    time: 1_725_000_000,
    expires: Some(1_725_043_200),
    event: message.MessageEvent,
    topic: alerts,
    message: "Disk space is low",
    title: Some("Production"),
    priority: message.High,
    tags: ["warning", "disk"],
    markdown: True,
    icon: Some("https://example.test/icon.png"),
    click: Some("https://example.test/incidents/42"),
    actions: [
      message.ViewAction(
        label: "Open incident",
        url: "https://example.test/incidents/42",
        clear: True,
        id: Some("Action0001"),
      ),
      message.CopyAction(
        label: "Copy ID",
        value: "INC-42",
        clear: False,
        id: Some("Action0002"),
      ),
    ],
    attachment: Some(message.Attachment(
      name: "report.txt",
      url: "https://example.test/report.txt",
      mime_type: Some("text/plain"),
      size: Some(42),
      expires: Some(1_725_043_200),
    )),
    scheduled: False,
    cached: True,
    sequence_id: Some("incident-42"),
    poll_id: None,
  )
  |> message_json.encode
  |> json.to_string
  |> birdie.snap(title: "complete ntfy message wire JSON")
}

pub fn action_alias_normalisation_snapshot_test() {
  action.parse(
    "http, Acknowledge, https://api.example.test/incidents/42, method=patch, headers.X-Trace=request-42, body=\"{\\\"ok\\\":true}\", clear=yes",
  )
  |> string.inspect
  |> birdie.snap(title: "action alias normalization")
}

pub fn publish_validation_errors_snapshot_test() {
  [
    message_json.decode_publish("{"),
    message_json.decode_publish(
      "{\"topic\":\"bad/topic\",\"message\":\"unsafe\"}",
    ),
    message_json.decode_publish(
      "{\"topic\":\"alerts\",\"message\":\"x\",\"priority\":9}",
    ),
  ]
  |> string.inspect
  |> birdie.snap(title: "publish validation errors")
}
