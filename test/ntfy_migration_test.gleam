import gleam/bit_array
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import notify/access
import notify/attachment_store
import notify/attachment_store/filesystem
import notify/attachment_store/memory as attachment_memory
import notify/core/acl
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/identity/sqlite as identity_sqlite
import notify/migration/ntfy
import notify/storage
import notify/storage/sqlite
import notify/webpush/sqlite as webpush_sqlite
import sqlight

const bcrypt_fixture = "$2a$10$YLiO8U21sX1uhZamTLJXHuxgVC0Z/GKISibrKCLohPgtG7yIxSk4C"

fn create_cache(path: String, invalid_topic: Bool) {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, mid TEXT NOT NULL, sequence_id TEXT NOT NULL, time INT NOT NULL, event TEXT NOT NULL, expires INT NOT NULL, topic TEXT NOT NULL, message TEXT NOT NULL, title TEXT NOT NULL, priority INT NOT NULL, tags TEXT NOT NULL, click TEXT NOT NULL, icon TEXT NOT NULL, actions TEXT NOT NULL, attachment_name TEXT NOT NULL, attachment_type TEXT NOT NULL, attachment_size INT NOT NULL, attachment_expires INT NOT NULL, attachment_url TEXT NOT NULL, attachment_deleted INT NOT NULL, sender TEXT NOT NULL, user TEXT NOT NULL, content_type TEXT NOT NULL, encoding TEXT NOT NULL, published INT NOT NULL); CREATE TABLE schemaVersion (id INT PRIMARY KEY, version INT NOT NULL); INSERT INTO schemaVersion VALUES (1, 15);",
      connection,
    )
  let topic_name = case invalid_topic {
    True -> "not/valid"
    False -> "alerts"
  }
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO messages(mid, sequence_id, time, event, expires, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, attachment_deleted, sender, user, content_type, encoding, published) VALUES (?, '', 1700000000, 'message', 1700043200, ?, 'from ntfy', 'Imported', 4, 'warning,migration', 'https://example.test', '', '', 'report.txt', 'text/plain', 0, 0, 'https://files.example.test/report.txt', 0, '', 'u_phil', 'text/markdown', '', 1)",
      on: connection,
      with: [sqlight.text("AbCdEf1234XY"), sqlight.text(topic_name)],
      expecting: decode.dynamic,
    )
  assert sqlight.close(connection) == Ok(Nil)
}

fn create_auth(path: String) {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE user (id TEXT PRIMARY KEY, user TEXT NOT NULL, pass TEXT NOT NULL, role TEXT NOT NULL, created INT NOT NULL, deleted INT); CREATE TABLE user_access (user_id TEXT NOT NULL, topic TEXT NOT NULL, read INT NOT NULL, write INT NOT NULL, PRIMARY KEY(user_id, topic)); CREATE TABLE user_token (user_id TEXT NOT NULL, token TEXT NOT NULL, label TEXT NOT NULL, last_access INT NOT NULL, last_origin TEXT NOT NULL, expires INT NOT NULL, provisioned INT NOT NULL, PRIMARY KEY(user_id, token)); CREATE TABLE schemaVersion (id INT PRIMARY KEY, version INT NOT NULL); INSERT INTO schemaVersion VALUES (1, 9);",
      connection,
    )
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO user(id, user, pass, role, created, deleted) VALUES ('u_phil', 'phil', ?, 'admin', 1690000000, NULL), ('u_everyone', '*', '', 'anonymous', 1690000000, NULL)",
      on: connection,
      with: [sqlight.text(bcrypt_fixture)],
      expecting: decode.dynamic,
    )
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO user_access(user_id, topic, read, write) VALUES ('u_phil', 'alerts', 1, 1), ('u_everyone', 'public%', 1, 0); INSERT INTO user_token(user_id, token, label, last_access, last_origin, expires, provisioned) VALUES ('u_phil', 'tk_fixturetoken', 'phone', 1690000001, '', 1800000000, 0);",
      connection,
    )
  assert sqlight.close(connection) == Ok(Nil)
}

fn create_webpush(path: String) {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE subscription (id TEXT PRIMARY KEY, endpoint TEXT NOT NULL, key_auth TEXT NOT NULL, key_p256dh TEXT NOT NULL, user_id TEXT NOT NULL, subscriber_ip TEXT NOT NULL, updated_at INT NOT NULL, warned_at INT NOT NULL DEFAULT 0); CREATE TABLE subscription_topic (subscription_id TEXT NOT NULL, topic TEXT NOT NULL, PRIMARY KEY(subscription_id, topic)); INSERT INTO subscription VALUES ('wp_1', 'https://fcm.googleapis.com/fcm/send/fixture', 'kSC3T8aN1JCQxxPdrFLrZg', 'BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE', 'u_phil', '192.0.2.10', 1690000002, 0); INSERT INTO subscription_topic VALUES ('wp_1', 'alerts');",
      connection,
    )
  assert sqlight.close(connection) == Ok(Nil)
}

fn create_v9_cache(path: String) {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, mid TEXT NOT NULL, time INT NOT NULL, topic TEXT NOT NULL, message TEXT NOT NULL, title TEXT NOT NULL, priority INT NOT NULL, tags TEXT NOT NULL, click TEXT NOT NULL, attachment_name TEXT NOT NULL, attachment_type TEXT NOT NULL, attachment_size INT NOT NULL, attachment_expires INT NOT NULL, attachment_url TEXT NOT NULL, sender TEXT NOT NULL, encoding TEXT NOT NULL, published INT NOT NULL, actions TEXT NOT NULL, icon TEXT NOT NULL); CREATE TABLE schemaVersion (id INT PRIMARY KEY, version INT NOT NULL); INSERT INTO schemaVersion VALUES (1, 9); INSERT INTO messages(mid, time, topic, message, title, priority, tags, click, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, sender, encoding, published, actions, icon) VALUES ('OldCache09XY', 1000, 'legacy', 'old schema', '', 3, '', '', '', '', 0, 0, '', '', '', 1, '', '');",
      connection,
    )
  assert sqlight.close(connection) == Ok(Nil)
}

fn create_local_attachment_cache(path: String, id: String, size: Int) {
  let assert Ok(connection) = sqlight.open(path)
  let assert Ok(_) =
    sqlight.exec(
      "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, mid TEXT NOT NULL, sequence_id TEXT NOT NULL, time INT NOT NULL, event TEXT NOT NULL, expires INT NOT NULL, topic TEXT NOT NULL, message TEXT NOT NULL, title TEXT NOT NULL, priority INT NOT NULL, tags TEXT NOT NULL, click TEXT NOT NULL, icon TEXT NOT NULL, actions TEXT NOT NULL, attachment_name TEXT NOT NULL, attachment_type TEXT NOT NULL, attachment_size INT NOT NULL, attachment_expires INT NOT NULL, attachment_url TEXT NOT NULL, attachment_deleted INT NOT NULL, sender TEXT NOT NULL, user TEXT NOT NULL, content_type TEXT NOT NULL, encoding TEXT NOT NULL, published INT NOT NULL); CREATE TABLE schemaVersion (id INT PRIMARY KEY, version INT NOT NULL); INSERT INTO schemaVersion VALUES (1, 15);",
      connection,
    )
  let assert Ok(_) =
    sqlight.query(
      "INSERT INTO messages(mid, sequence_id, time, event, expires, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, attachment_deleted, sender, user, content_type, encoding, published) VALUES (?, '', 1700000000, 'message', 1700043200, 'files', 'local file', '', 3, '', '', '', '', 'sample.bin', 'application/octet-stream', ?, 1700010000, 'https://old.example/file', 0, '', '', '', '', 1)",
      on: connection,
      with: [sqlight.text(id), sqlight.int(size)],
      expecting: decode.dynamic,
    )
  assert sqlight.close(connection) == Ok(Nil)
}

fn options(
  cache: String,
  auth: String,
  webpush: String,
  destination: String,
  dry_run: Bool,
) -> ntfy.Options {
  ntfy.Options(
    cache_file: Some(cache),
    auth_file: Some(auth),
    webpush_file: Some(webpush),
    attachment_directory: None,
    destination_file: destination,
    destination_attachments: None,
    base_url: "https://notify.example.test",
    default_access: acl.Deny,
    cache_duration_seconds: 43_200,
    now: 1_700_000_100,
    dry_run:,
  )
}

pub fn ntfy_v227_migration_is_dry_runnable_source_preserving_and_idempotent_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let cache = directory <> "/cache.db"
  let auth = directory <> "/auth.db"
  let webpush = directory <> "/webpush.db"
  let destination = directory <> "/notify.db"
  create_cache(cache, False)
  create_auth(auth)
  create_webpush(webpush)
  let assert Ok(before) = ntfy.source_digests([cache, auth, webpush])

  let assert Ok(preview) =
    ntfy.run(options(cache, auth, webpush, destination, True))
  assert preview.messages == ntfy.Counts(scanned: 1, migrated: 1, skipped: 0)
  assert preview.users == ntfy.Counts(scanned: 1, migrated: 1, skipped: 0)
  assert preview.tokens == ntfy.Counts(scanned: 1, migrated: 1, skipped: 0)
  assert preview.acl_rules == ntfy.Counts(scanned: 2, migrated: 2, skipped: 0)
  assert preview.webpush_subscriptions
    == ntfy.Counts(scanned: 1, migrated: 1, skipped: 0)
  assert ntfy.path_exists(destination) == False

  let assert Ok(applied) =
    ntfy.run(options(cache, auth, webpush, destination, False))
  assert applied.messages.migrated == 1
  assert applied.users.migrated == 1

  let assert Ok(messages) = sqlite.start(destination)
  let assert Ok(alerts) = topic.parse("alerts")
  let assert Ok([imported]) =
    messages.query(storage.Query(
      topics: [alerts],
      since: storage.All,
      include_scheduled: True,
      criteria: filter.none(),
    ))
  assert imported.id == "AbCdEf1234XY"
  assert imported.message == "from ntfy"
  assert imported.title == Some("Imported")
  assert imported.priority == message.High
  assert imported.tags == ["warning", "migration"]
  assert imported.markdown == True
  assert imported.scheduled == False

  let assert Ok(identity) = identity_sqlite.open_store(destination)
  let assert Ok(control) = access.managed(identity)
  let assert Ok([user]) = access.list_users(control)
  assert user.username == "phil"
  assert user.password_hash == bcrypt_fixture
  assert access.authenticate(
      control,
      access.Basic("phil", "phil"),
      1_700_000_100,
    )
    == Ok(acl.Authenticated("phil", acl.Admin))
  let assert Ok(rehashed) = access.user_by_name(control, "phil")
  assert string.starts_with(rehashed.password_hash, "$argon2id$")
  let assert Error(access.InvalidCredentials) =
    access.authenticate(control, access.Basic("phil", "wrong"), 1_700_000_101)
  assert access.default_access(control) == Ok(acl.Deny)
  let assert Ok(grants) = access.list_grants(control, None)
  assert list.length(grants) == 2
  let assert Ok(tokens) = access.list_tokens(control, "phil")
  let assert [migrated_token] = tokens
  assert migrated_token.last_access == Some(1_690_000_001)

  let assert Ok(push) = webpush_sqlite.start(destination, 10)
  let assert Ok([subscription]) = push.for_topic("alerts")
  assert subscription.id == "wp_1"
  assert subscription.user_id == Some("u_phil")

  let assert Ok(again) =
    ntfy.run(options(cache, auth, webpush, destination, False))
  assert again.messages == ntfy.Counts(scanned: 1, migrated: 0, skipped: 1)
  assert again.users == ntfy.Counts(scanned: 1, migrated: 0, skipped: 1)
  assert again.tokens == ntfy.Counts(scanned: 1, migrated: 0, skipped: 1)
  assert again.acl_rules == ntfy.Counts(scanned: 2, migrated: 0, skipped: 2)
  assert again.webpush_subscriptions
    == ntfy.Counts(scanned: 1, migrated: 0, skipped: 1)
  assert ntfy.source_digests([cache, auth, webpush]) == Ok(before)
}

pub fn invalid_ntfy_source_is_rejected_before_destination_is_created_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let cache = directory <> "/invalid-cache.db"
  let destination = directory <> "/notify.db"
  create_cache(cache, True)
  let migration =
    ntfy.Options(
      ..options(cache, "unused", "unused", destination, False),
      auth_file: None,
      webpush_file: None,
    )
  let assert Error(ntfy.InvalidSource(_)) = ntfy.run(migration)
  assert ntfy.path_exists(destination) == False
}

pub fn ntfy_yaml_database_hints_are_parsed_without_accepting_postgres_test() {
  assert ntfy.parse_source_config(
      "# ntfy v2.27.0\ncache-file: '/var/lib/ntfy/cache.db'\nauth-file: /var/lib/ntfy/auth.db # local users\nweb-push-file: \"/var/lib/ntfy/webpush.db\"\nattachment-cache-dir: /var/lib/ntfy/attachments\nauth-default-access: read-only\nkeepalive-interval: 45s\n",
    )
    == Ok(ntfy.SourceConfig(
      cache_file: Some("/var/lib/ntfy/cache.db"),
      auth_file: Some("/var/lib/ntfy/auth.db"),
      webpush_file: Some("/var/lib/ntfy/webpush.db"),
      attachment_directory: Some("/var/lib/ntfy/attachments"),
      default_access: Some(acl.ReadOnly),
    ))
  let assert Error(ntfy.InvalidSource(_)) =
    ntfy.parse_source_config("database-url: postgres://ntfy@db/ntfy\n")
}

pub fn ntfy_v9_cache_backfills_expiry_using_configured_retention_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let source = directory <> "/cache-v9.db"
  let destination = directory <> "/notify.db"
  create_v9_cache(source)
  let assert Ok(report) =
    ntfy.run(ntfy.Options(
      cache_file: Some(source),
      auth_file: None,
      webpush_file: None,
      attachment_directory: None,
      destination_file: destination,
      destination_attachments: None,
      base_url: "https://notify.example.test",
      default_access: acl.ReadWrite,
      cache_duration_seconds: 600,
      now: 2000,
      dry_run: False,
    ))
  assert report.messages.migrated == 1
  let assert Ok(store) = sqlite.start(destination)
  let assert Ok(legacy) = topic.parse("legacy")
  let assert Ok([imported]) =
    store.query(storage.Query(
      topics: [legacy],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert imported.expires == Some(1600)
  assert imported.sequence_id == None
}

pub fn local_ntfy_attachments_are_content_addressed_and_rolled_back_on_db_failure_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let source = directory <> "/cache.db"
  let source_files = directory <> "/source-attachments"
  let assert Ok(_) =
    filesystem.start(source_files, max_file_bytes: 100, max_total_bytes: 100)
  let contents = <<"payload":utf8>>
  create_local_attachment_cache(
    source,
    "LocalAt001XY",
    bit_array.byte_size(contents),
  )
  assert write_binary_file(source_files <> "/LocalAt001XY", contents) == Ok(Nil)
  let assert Ok(target) =
    attachment_memory.start(max_file_bytes: 100, max_total_bytes: 100)
  let migration =
    ntfy.Options(
      cache_file: Some(source),
      auth_file: None,
      webpush_file: None,
      attachment_directory: Some(source_files),
      destination_file: directory <> "/notify.db",
      destination_attachments: Some(target),
      base_url: "https://notify.example.test",
      default_access: acl.ReadWrite,
      cache_duration_seconds: 43_200,
      now: 1_700_000_100,
      dry_run: False,
    )
  let assert Ok(first) = ntfy.run(migration)
  assert first.attachments == ntfy.Counts(1, 1, 0)
  let assert Ok([stored]) = target.list()
  assert stored.key == attachment_store.content_key(contents)
  let assert Ok(second) = ntfy.run(migration)
  assert second.attachments == ntfy.Counts(1, 0, 1)
  let assert Ok(imported_store) = sqlite.start(migration.destination_file)
  let assert Ok(files) = topic.parse("files")
  let assert Ok([imported]) =
    imported_store.query(storage.Query(
      topics: [files],
      since: storage.All,
      include_scheduled: True,
      criteria: filter.none(),
    ))
  let assert Some(imported_attachment) = imported.attachment
  assert string.ends_with(imported_attachment.url, "/sample.bin")
  assert imported_store.has_attachment(files, stored.key) == Ok(True)

  let conflict_destination = directory <> "/conflict.db"
  let assert Ok(conflict_store) = sqlite.start(conflict_destination)
  let conflicting =
    message.Message(
      id: "LocalAt001XY",
      time: 1_700_000_000,
      expires: Some(1_700_043_200),
      event: message.MessageEvent,
      topic: files,
      message: "different payload",
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
  assert conflict_store.save(conflicting) == Ok(conflicting)
  let assert Ok(rollback_target) =
    attachment_memory.start(max_file_bytes: 100, max_total_bytes: 100)
  let conflicting_migration =
    ntfy.Options(
      ..migration,
      destination_file: conflict_destination,
      destination_attachments: Some(rollback_target),
    )
  let assert Error(ntfy.DestinationUnavailable(_)) =
    ntfy.run(conflicting_migration)
  assert rollback_target.list() == Ok([])
}

@external(erlang, "notify_ffi", "write_binary_file")
fn write_binary_file(path: String, data: BitArray) -> Result(Nil, String)
