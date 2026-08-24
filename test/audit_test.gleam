import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import notify/audit
import notify/audit/memory
import notify/audit/sqlite
import notify/http/cursor
import sqlight

fn fixture(index: Int, outcome: audit.Outcome) -> audit.NewEvent {
  let assert Ok(event) =
    audit.new_event(
      occurred_at: 1000 + index,
      actor: "admin",
      action: audit.UserCreate,
      target: Some("user-" <> int.to_string(index)),
      outcome:,
      status: Some(201),
      client_ip: "203.0.113.10",
      request_id: "request-" <> int.to_string(index),
    )
  event
}

fn paging_contract(store: audit.Store) {
  let assert Ok(first) = store.append(fixture(1, audit.Attempted))
  let assert Ok(second) = store.append(fixture(2, audit.Succeeded))
  let assert Ok(third) = store.append(fixture(3, audit.Failed))
  assert first.sequence < second.sequence
  assert second.sequence < third.sequence

  let assert Ok(audit.Page([latest, previous], Some(next))) =
    store.page(None, 2)
  assert latest.sequence == third.sequence
  assert previous.sequence == second.sequence
  assert next.sequence == second.sequence

  let assert Ok(audit.Page([oldest], None)) = store.page(Some(next), 2)
  assert oldest.sequence == first.sequence
  assert store.page(None, 0) == Error(audit.InvalidPage)
  assert store.page(None, 101) == Error(audit.InvalidPage)
  assert store.health() == Ok(Nil)
}

pub fn memory_audit_is_append_only_and_keyset_paginated_test() {
  let assert Ok(store) = memory.start()
  paging_contract(store)
}

pub fn sqlite_audit_persists_and_uses_the_same_page_contract_test() {
  let path = temporary_path()
  let assert Ok(writer) = sqlite.start(path)
  paging_contract(writer)

  let assert Ok(reader) = sqlite.start(path)
  let assert Ok(audit.Page(items, None)) = reader.page(None, 100)
  assert list.length(items) == 3
}

pub fn sqlite_accepts_every_public_audit_action_test() {
  let assert Ok(store) = sqlite.start(temporary_path())
  let actions = [
    audit.SetupComplete,
    audit.SessionLogin,
    audit.SessionLogout,
    audit.UserCreate,
    audit.UserUpdate,
    audit.UserDelete,
    audit.PasswordChange,
    audit.TokenCreate,
    audit.TokenRevoke,
    audit.AclChange,
    audit.AclRevoke,
    audit.AnonymousAccessChange,
    audit.DeliveryRetry,
    audit.DeliveryPurge,
    audit.AttachmentDelete,
  ]
  actions
  |> list.index_map(fn(action, index) { #(action, index) })
  |> list.each(fn(pair) {
    let #(action, index) = pair
    let name = audit.action_name(action)
    assert audit.action_from_name(name) == Ok(action)
    let assert Ok(event) =
      audit.new_event(
        occurred_at: 1000 + index,
        actor: "admin",
        action:,
        target: None,
        outcome: audit.Denied,
        status: Some(403),
        client_ip: "203.0.113.10",
        request_id: "all-actions",
      )
    let assert Ok(stored) = store.append(event)
    assert stored.action == action
  })
}

pub fn sqlite_rejects_an_unsupported_audit_schema_before_migration_test() {
  let path = temporary_path()
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE audit_log (sequence INTEGER PRIMARY KEY, occurred_at INTEGER NOT NULL)",
      connection,
    )
  let _ = sqlight.close(connection)

  let assert Error(audit.Corrupt(detail)) = sqlite.start(path)
  assert string.contains(detail, "database was not modified")
}

pub fn audit_fields_are_bounded_and_reject_control_characters_test() {
  assert audit.new_event(
      occurred_at: 1000,
      actor: "admin\nforged",
      action: audit.SessionLogin,
      target: None,
      outcome: audit.Denied,
      status: Some(401),
      client_ip: "203.0.113.10",
      request_id: "request-1",
    )
    == Error(audit.InvalidEvent("actor"))
  assert audit.new_event(
      occurred_at: 1000,
      actor: "admin",
      action: audit.SessionLogin,
      target: Some(string.repeat("x", times: 257)),
      outcome: audit.Denied,
      status: Some(401),
      client_ip: "203.0.113.10",
      request_id: "request-1",
    )
    == Error(audit.InvalidEvent("target"))
}

pub fn api_cursor_is_opaque_versioned_and_resource_scoped_test() {
  let encoded = cursor.encode("audit", 42)
  assert encoded != "42"
  assert !string.contains(encoded, ":")
  assert cursor.decode(encoded, "audit") == Ok(42)
  assert cursor.decode(encoded, "users") == Error(cursor.InvalidCursor)
  assert cursor.decode("not+base64", "audit") == Error(cursor.InvalidCursor)
}

fn temporary_path() -> String {
  let assert Ok(directory) = make_temporary_directory()
  string.trim_end(directory) <> "/notify.db"
}

@external(erlang, "notify_ffi", "make_temporary_directory")
fn make_temporary_directory() -> Result(String, Nil)
