import gleeunit
import notify_web

pub fn main() -> Nil {
  gleeunit.main()
}

fn item(id: String, body: String) -> notify_web.Notification {
  notify_web.Notification(
    id:,
    topic: "alerts",
    title: "",
    body:,
    time: 100,
    priority: 3,
    sequence_id: "",
  )
}

pub fn language_topic_and_filter_state_are_deterministic_test() {
  let initial = notify_web.initial_model()
  let japanese = notify_web.reduce(initial, notify_web.UserChangedLanguage)
  assert japanese.language == notify_web.Japanese

  let opened = notify_web.reduce(japanese, notify_web.UserOpenedTopic("alerts"))
  assert opened.topic == "alerts"
  assert opened.connection == notify_web.Connecting

  let loaded =
    notify_web.reduce(
      opened,
      notify_web.ServerLoadedHistory([item("Message001", "Deploy complete")]),
    )
  let filtered =
    notify_web.reduce(loaded, notify_web.UserChangedFilter("deploy"))
  assert notify_web.visible_notifications(filtered)
    == [item("Message001", "Deploy complete")]
  assert notify_web.visible_notifications(notify_web.reduce(
      filtered,
      notify_web.UserChangedFilter("missing"),
    ))
    == []
}

pub fn live_notifications_are_ordered_and_deduplicated_by_id_test() {
  let model =
    notify_web.initial_model()
    |> notify_web.reduce(notify_web.UserOpenedTopic("alerts"))
    |> notify_web.reduce(
      notify_web.ServerLoadedHistory([
        item("Message001", "one"),
      ]),
    )
    |> notify_web.reduce(
      notify_web.ServerSentNotification(item("Message002", "two")),
    )
    |> notify_web.reduce(
      notify_web.ServerSentNotification(item("Message002", "duplicate")),
    )
  assert model.notifications
    == [item("Message001", "one"), item("Message002", "two")]
}

pub fn sequence_updates_replace_and_control_events_remove_timeline_rows_test() {
  let first =
    notify_web.Notification(
      ..item("Message001", "old"),
      sequence_id: "deploy-42",
    )
  let updated =
    notify_web.Notification(
      ..item("Message002", "new"),
      sequence_id: "deploy-42",
    )
  let model =
    notify_web.initial_model()
    |> notify_web.reduce(notify_web.ServerSentNotification(first))
    |> notify_web.reduce(notify_web.ServerSentNotification(updated))
  assert model.notifications == [updated]

  let cleared =
    notify_web.reduce(
      model,
      notify_web.ServerRemovedSequence("alerts", "deploy-42"),
    )
  assert cleared.notifications == []
}

pub fn administration_forms_keep_secrets_one_time_and_refresh_inventory_test() {
  let edited =
    notify_web.initial_model()
    |> notify_web.reduce(notify_web.UserChangedAdminUsername("operator"))
    |> notify_web.reduce(notify_web.UserChangedAdminPassword(
      "a secure operator password",
    ))
    |> notify_web.reduce(notify_web.UserChangedAdminRole("admin"))
    |> notify_web.reduce(notify_web.UserChangedTokenLabel("deploy bot"))
    |> notify_web.reduce(notify_web.UserChangedAclPattern("deploy-*"))
    |> notify_web.reduce(notify_web.UserChangedAclPermission("read-write"))
  assert edited.admin_username == "operator"
  assert edited.admin_password == "a secure operator password"
  assert edited.admin_role == "admin"
  assert edited.token_label == "deploy bot"
  assert edited.acl_pattern == "deploy-*"
  assert edited.acl_permission == "read-write"

  let completed =
    notify_web.reduce(
      edited,
      notify_web.ServerCompletedAdminMutation(
        True,
        "Token created",
        "tk_show_once",
      ),
    )
  assert completed.admin_password == ""
  assert completed.admin_status == "Token created"
  assert completed.issued_token == "tk_show_once"

  let loaded =
    notify_web.reduce(
      completed,
      notify_web.ServerLoadedAdmin(
        "healthy",
        "operator · admin",
        "operator → deploy-*: read-write",
        "webpush · dead_letter · 4 attempts",
        "abc123 · 42 bytes",
      ),
    )
  assert loaded.delivery_jobs == ["webpush · dead_letter · 4 attempts"]
  assert loaded.attachments == ["abc123 · 42 bytes"]
}
