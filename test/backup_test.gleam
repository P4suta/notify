import gleam/list
import gleam/option.{None}
import notify/attachment_store/filesystem
import notify/backup
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/storage
import notify/storage/sqlite
import sqlight

fn fixture() -> message.Message {
  let assert Ok(topic) = topic.parse("backups")
  message.Message(
    id: "Backup0001",
    time: 100,
    expires: None,
    event: message.MessageEvent,
    topic:,
    message: "durable",
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
  )
}

pub fn online_sqlite_backup_and_restore_preserve_committed_messages_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let source = directory <> "/notify.db"
  let snapshot = directory <> "/notify.backup.db"
  let restored = directory <> "/restored.db"
  let assert Ok(store) = sqlite.start(source)
  assert store.save(fixture()) == Ok(fixture())

  assert backup.create_sqlite(source, snapshot) == Ok(Nil)
  assert backup.verify_sqlite(snapshot) == Ok(Nil)
  assert backup.restore_sqlite(snapshot, restored) == Ok(Nil)

  let assert Ok(restored_store) = sqlite.start(restored)
  let assert Ok(backups) = topic.parse("backups")
  let assert Ok(messages) =
    restored_store.query(storage.Query(
      topics: [backups],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.map(messages, fn(item) { item.id }) == ["Backup0001"]
}

pub fn backup_refuses_to_overwrite_and_rejects_non_notify_databases_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let source = directory <> "/notify.db"
  let destination = directory <> "/snapshot.db"
  let assert Ok(_) = sqlite.start(source)
  assert backup.create_sqlite(source, destination) == Ok(Nil)
  assert backup.create_sqlite(source, destination)
    == Error(backup.DestinationExists)

  let empty_database = directory <> "/empty.db"
  let assert Ok(connection) = sqlight.open(empty_database)
  assert sqlight.close(connection) == Ok(Nil)
  assert backup.verify_sqlite(empty_database) == Error(backup.NotNotifyDatabase)
}
