import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import notify/attachment_store
import notify/core/acl
import notify/core/message
import notify/core/message_json
import notify/core/topic
import notify/identity
import notify/identity/sqlite as identity_sqlite
import notify/security/password
import notify/security/token as security_token
import notify/sqlite_lock
import notify/storage/sqlite as storage_sqlite
import notify/webpush
import notify/webpush/sqlite as webpush_sqlite
import sqlight.{type Connection}

pub type Options {
  Options(
    cache_file: Option(String),
    auth_file: Option(String),
    webpush_file: Option(String),
    attachment_directory: Option(String),
    destination_file: String,
    destination_attachments: Option(attachment_store.Store),
    base_url: String,
    default_access: acl.Permission,
    cache_duration_seconds: Int,
    now: Int,
    dry_run: Bool,
  )
}

pub type Counts {
  Counts(scanned: Int, migrated: Int, skipped: Int)
}

pub type Report {
  Report(
    messages: Counts,
    users: Counts,
    tokens: Counts,
    acl_rules: Counts,
    webpush_subscriptions: Counts,
    attachments: Counts,
    source_digests: List(#(String, String)),
    dry_run: Bool,
  )
}

pub type Error {
  SourceUnavailable(path: String, detail: String)
  UnsupportedSchema(store: String, version: Int)
  InvalidSource(String)
  SourceChanged(String)
  DestinationUnavailable(String)
  AttachmentError(attachment_store.Error)
}

pub type SourceConfig {
  SourceConfig(
    cache_file: Option(String),
    auth_file: Option(String),
    webpush_file: Option(String),
    attachment_directory: Option(String),
    default_access: Option(acl.Permission),
  )
}

type SourceMessage {
  SourceMessage(value: message.Message, local: Option(LocalAttachment))
}

type LocalAttachment {
  LocalAttachment(message_id: String, size: Int, expires: Int)
}

type ReadyMessage {
  ReadyMessage(value: message.Message, attachment_data: Option(BitArray))
}

type SourceUser {
  SourceUser(
    id: String,
    username: String,
    role: acl.Role,
    password_hash: String,
    created_at: Int,
  )
}

type SourceToken {
  SourceToken(
    user_id: String,
    raw: String,
    label: String,
    created_at: Int,
    expires: Option(Int),
    last_access: Option(Int),
  )
}

type SourcePush {
  SourcePush(
    id: String,
    endpoint: String,
    auth: String,
    p256dh: String,
    user_id: Option(String),
    subscriber_ip: String,
    updated_at: Int,
    topics: List(String),
  )
}

type Loaded {
  Loaded(
    messages: List(SourceMessage),
    users: List(SourceUser),
    tokens: List(SourceToken),
    rules: List(acl.Rule),
    pushes: List(SourcePush),
    auth_present: Bool,
  )
}

type Applied {
  Applied(
    messages: Counts,
    users: Counts,
    tokens: Counts,
    rules: Counts,
    pushes: Counts,
  )
}

type Attached {
  Attached(
    messages: List(message.Message),
    counts: Counts,
    new_keys: List(String),
  )
}

pub fn run(options: Options) -> Result(Report, Error) {
  let paths = source_paths(options)
  use before <- result.try(source_digests(paths))
  use loaded <- result.try(load_all(options))
  use ready <- result.try(load_attachment_data(
    loaded.messages,
    options.attachment_directory,
  ))
  use after <- result.try(source_digests(paths))
  use _ <- result.try(case before == after {
    True -> Ok(Nil)
    False -> Error(SourceChanged("an ntfy source changed while it was read"))
  })

  case options.dry_run {
    True ->
      Ok(Report(
        messages: prospective(list.length(ready)),
        users: prospective(list.length(loaded.users)),
        tokens: prospective(list.length(loaded.tokens)),
        acl_rules: prospective(list.length(loaded.rules)),
        webpush_subscriptions: prospective(list.length(loaded.pushes)),
        attachments: prospective(count_ready_attachments(ready)),
        source_digests: before,
        dry_run: True,
      ))
    False -> apply(options, loaded, ready, before)
  }
}

/// Reads the flat database-related keys from ntfy's `server.yml`. Unknown
/// settings are deliberately ignored, while a PostgreSQL source is rejected
/// because this importer guarantees byte-for-byte preservation of SQLite
/// inputs.
pub fn read_source_config(path: String) -> Result(SourceConfig, Error) {
  use contents <- result.try(
    read_text_file(path)
    |> result.map_error(fn(_) {
      SourceUnavailable(path, "file could not be read")
    }),
  )
  parse_source_config(contents)
}

pub fn parse_source_config(contents: String) -> Result(SourceConfig, Error) {
  parse_config_lines(
    string.split(contents, "\n"),
    SourceConfig(None, None, None, None, None),
  )
}

fn parse_config_lines(
  lines: List(String),
  config: SourceConfig,
) -> Result(SourceConfig, Error) {
  case lines {
    [] -> Ok(config)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case string.is_empty(trimmed) || string.starts_with(trimmed, "#") {
        True -> parse_config_lines(rest, config)
        False ->
          case string.split_once(trimmed, on: ":") {
            Error(_) -> parse_config_lines(rest, config)
            Ok(#(raw_key, raw_value)) -> {
              let key = string.trim(raw_key)
              let value = yaml_scalar(raw_value)
              case key, value {
                "database-url", "" -> parse_config_lines(rest, config)
                "database-url", _ ->
                  Error(InvalidSource(
                    "PostgreSQL-backed ntfy migration is not supported by the offline SQLite importer",
                  ))
                "cache-file", value ->
                  parse_config_lines(
                    rest,
                    SourceConfig(..config, cache_file: nonempty(value)),
                  )
                "auth-file", value ->
                  parse_config_lines(
                    rest,
                    SourceConfig(..config, auth_file: nonempty(value)),
                  )
                "web-push-file", value ->
                  parse_config_lines(
                    rest,
                    SourceConfig(..config, webpush_file: nonempty(value)),
                  )
                "attachment-cache-dir", value ->
                  parse_config_lines(
                    rest,
                    SourceConfig(
                      ..config,
                      attachment_directory: nonempty(value),
                    ),
                  )
                "auth-default-access", value -> {
                  use permission <- result.try(parse_source_permission(value))
                  parse_config_lines(
                    rest,
                    SourceConfig(..config, default_access: Some(permission)),
                  )
                }
                _, _ -> parse_config_lines(rest, config)
              }
            }
          }
      }
    }
  }
}

fn yaml_scalar(raw: String) -> String {
  let value = string.trim(raw)
  let value = case string.split_once(value, on: " #") {
    Ok(#(value, _)) -> string.trim(value)
    Error(_) -> value
  }
  case
    string.length(value) >= 2,
    string.starts_with(value, "\"") && string.ends_with(value, "\""),
    string.starts_with(value, "'") && string.ends_with(value, "'")
  {
    True, True, _ | True, _, True ->
      value |> string.drop_start(1) |> string.drop_end(1)
    _, _, _ -> value
  }
}

fn parse_source_permission(value: String) -> Result(acl.Permission, Error) {
  case string.lowercase(value) {
    "deny-all" | "deny" -> Ok(acl.Deny)
    "read-only" | "read" -> Ok(acl.ReadOnly)
    "write-only" | "write" -> Ok(acl.WriteOnly)
    "read-write" -> Ok(acl.ReadWrite)
    _ -> Error(InvalidSource("invalid auth-default-access in ntfy YAML"))
  }
}

fn apply(
  options: Options,
  loaded: Loaded,
  ready: List(ReadyMessage),
  digests: List(#(String, String)),
) -> Result(Report, Error) {
  use lock <- result.try(
    sqlite_lock.acquire(options.destination_file)
    |> result.map_error(fn(error) {
      DestinationUnavailable(
        "destination is in use; stop Notify before migrating ("
        <> string.inspect(error)
        <> ")",
      )
    }),
  )
  let outcome = apply_locked(options, loaded, ready, digests)
  sqlite_lock.release(lock)
  outcome
}

fn apply_locked(
  options: Options,
  loaded: Loaded,
  ready: List(ReadyMessage),
  digests: List(#(String, String)),
) -> Result(Report, Error) {
  use _ <- result.try(prepare_destination(options.destination_file))
  use attached <- result.try(apply_attachments(options, ready))
  let applied = apply_database(options, loaded, attached.messages)
  case applied {
    Error(error) -> {
      rollback_attachments(options.destination_attachments, attached.new_keys)
      Error(error)
    }
    Ok(applied) ->
      Ok(Report(
        messages: applied.messages,
        users: applied.users,
        tokens: applied.tokens,
        acl_rules: applied.rules,
        webpush_subscriptions: applied.pushes,
        attachments: attached.counts,
        source_digests: digests,
        dry_run: False,
      ))
  }
}

fn source_paths(options: Options) -> List(String) {
  [options.cache_file, options.auth_file, options.webpush_file]
  |> list.fold([], fn(paths, path) {
    case path {
      Some(path) -> [path, ..paths]
      None -> paths
    }
  })
  |> list.reverse
}

pub fn source_digests(
  paths: List(String),
) -> Result(List(#(String, String)), Error) {
  list.try_map(paths, fn(path) {
    file_sha256(path)
    |> result.map(fn(digest) { #(path, digest) })
    |> result.map_error(fn(detail) { SourceUnavailable(path, detail) })
  })
}

pub fn path_exists(path: String) -> Bool {
  ffi_path_exists(path)
}

fn prospective(scanned: Int) -> Counts {
  Counts(scanned:, migrated: scanned, skipped: 0)
}

fn load_all(options: Options) -> Result(Loaded, Error) {
  use messages <- result.try(case options.cache_file {
    None -> Ok([])
    Some(path) -> load_cache(path, options.cache_duration_seconds)
  })
  use auth <- result.try(case options.auth_file {
    None -> Ok(#([], [], []))
    Some(path) -> load_auth(path, options.now)
  })
  use pushes <- result.try(case options.webpush_file {
    None -> Ok([])
    Some(path) -> load_webpush(path)
  })
  Ok(Loaded(
    messages:,
    users: auth.0,
    tokens: auth.1,
    rules: auth.2,
    pushes:,
    auth_present: option_is_some(options.auth_file),
  ))
}

fn load_cache(
  path: String,
  cache_duration: Int,
) -> Result(List(SourceMessage), Error) {
  with_readonly(path, fn(connection) {
    use version <- result.try(schema_version(connection, path, "cache"))
    use query <- result.try(cache_query(version))
    let parameters = case version {
      9 -> [sqlight.int(int.max(0, cache_duration))]
      _ -> []
    }
    use rows <- result.try(
      sqlight.query(
        query,
        on: connection,
        with: parameters,
        expecting: source_message_decoder(),
      )
      |> result.map_error(fn(error) { source_sql_error(path, error) }),
    )
    list.try_map(rows, normalise_source_message)
  })
}

fn cache_query(version: Int) -> Result(String, Error) {
  case version {
    9 ->
      Ok(
        "SELECT mid, '', time, 'message', time + ?, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, 0, '', '', encoding, published FROM messages ORDER BY id",
      )
    10 | 11 ->
      Ok(
        "SELECT mid, '', time, 'message', expires, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, attachment_deleted, user, '', encoding, published FROM messages ORDER BY id",
      )
    12 | 13 ->
      Ok(
        "SELECT mid, '', time, 'message', expires, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, attachment_deleted, user, content_type, encoding, published FROM messages ORDER BY id",
      )
    14 | 15 ->
      Ok(
        "SELECT mid, sequence_id, time, event, expires, topic, message, title, priority, tags, click, icon, actions, attachment_name, attachment_type, attachment_size, attachment_expires, attachment_url, attachment_deleted, user, content_type, encoding, published FROM messages ORDER BY id",
      )
    other -> Error(UnsupportedSchema("cache", other))
  }
}

fn source_message_decoder() -> decode.Decoder(SourceMessageRow) {
  use id <- decode.field(0, decode.string)
  use sequence_id <- decode.field(1, decode.string)
  use time <- decode.field(2, decode.int)
  use event <- decode.field(3, decode.string)
  use expires <- decode.field(4, decode.int)
  use topic <- decode.field(5, decode.string)
  use body <- decode.field(6, decode.string)
  use title <- decode.field(7, decode.string)
  use priority <- decode.field(8, decode.int)
  use tags <- decode.field(9, decode.string)
  use click <- decode.field(10, decode.string)
  use icon <- decode.field(11, decode.string)
  use actions <- decode.field(12, decode.string)
  use attachment_name <- decode.field(13, decode.string)
  use attachment_type <- decode.field(14, decode.string)
  use attachment_size <- decode.field(15, decode.int)
  use attachment_expires <- decode.field(16, decode.int)
  use attachment_url <- decode.field(17, decode.string)
  use attachment_deleted <- decode.field(18, decode.int)
  use user <- decode.field(19, decode.string)
  use content_type <- decode.field(20, decode.string)
  use encoding <- decode.field(21, decode.string)
  use published <- decode.field(22, decode.int)
  decode.success(SourceMessageRow(
    id:,
    sequence_id:,
    time:,
    event:,
    expires:,
    topic:,
    body:,
    title:,
    priority:,
    tags:,
    click:,
    icon:,
    actions:,
    attachment_name:,
    attachment_type:,
    attachment_size:,
    attachment_expires:,
    attachment_url:,
    attachment_deleted:,
    user:,
    content_type:,
    encoding:,
    published:,
  ))
}

type SourceMessageRow {
  SourceMessageRow(
    id: String,
    sequence_id: String,
    time: Int,
    event: String,
    expires: Int,
    topic: String,
    body: String,
    title: String,
    priority: Int,
    tags: String,
    click: String,
    icon: String,
    actions: String,
    attachment_name: String,
    attachment_type: String,
    attachment_size: Int,
    attachment_expires: Int,
    attachment_url: String,
    attachment_deleted: Int,
    user: String,
    content_type: String,
    encoding: String,
    published: Int,
  )
}

fn normalise_source_message(
  row: SourceMessageRow,
) -> Result(SourceMessage, Error) {
  use parsed_topic <- result.try(
    topic.parse(row.topic)
    |> result.map_error(fn(_) {
      InvalidSource("invalid topic in ntfy cache: " <> row.topic)
    }),
  )
  use priority <- result.try(
    message.priority_from_int(row.priority)
    |> result.map_error(fn(_) {
      InvalidSource("invalid priority in ntfy cache")
    }),
  )
  use event <- result.try(parse_event(row.event))
  use actions <- result.try(case row.actions {
    "" -> Ok([])
    encoded ->
      message_json.decode_actions(encoded)
      |> result.map_error(fn(_) {
        InvalidSource("invalid action JSON in ntfy cache")
      })
  })
  use _ <- result.try(case message.valid_id(row.id), row.encoding {
    False, _ ->
      Error(InvalidSource("invalid message ID in ntfy cache: " <> row.id))
    _, "" -> Ok(Nil)
    _, _ ->
      Error(InvalidSource(
        "base64-encoded UnifiedPush messages cannot be represented safely",
      ))
  })
  let attachment = case row.attachment_name, row.attachment_url {
    "", _ | _, "" -> None
    name, url ->
      Some(message.Attachment(
        name:,
        url:,
        mime_type: nonempty(row.attachment_type),
        size: positive(row.attachment_size),
        expires: positive(row.attachment_expires),
      ))
  }
  let local = case
    attachment,
    row.attachment_size > 0,
    row.attachment_expires > 0,
    row.attachment_deleted == 0
  {
    Some(_), True, True, True ->
      Some(LocalAttachment(row.id, row.attachment_size, row.attachment_expires))
    _, _, _, _ -> None
  }
  Ok(SourceMessage(
    value: message.Message(
      id: row.id,
      time: row.time,
      expires: positive(row.expires),
      event:,
      topic: parsed_topic,
      message: row.body,
      title: nonempty(row.title),
      priority:,
      tags: split_tags(row.tags),
      markdown: string.lowercase(row.content_type) == "text/markdown",
      icon: nonempty(row.icon),
      click: nonempty(row.click),
      actions:,
      attachment:,
      scheduled: row.published == 0,
      cached: True,
      sequence_id: nonempty(row.sequence_id),
    ),
    local:,
  ))
}

fn parse_event(value: String) -> Result(message.Event, Error) {
  case value {
    "message" -> Ok(message.MessageEvent)
    "message_delete" -> Ok(message.MessageDeleteEvent)
    "message_clear" -> Ok(message.MessageClearEvent)
    _ -> Error(InvalidSource("unsupported cached ntfy event: " <> value))
  }
}

fn load_auth(
  path: String,
  now: Int,
) -> Result(#(List(SourceUser), List(SourceToken), List(acl.Rule)), Error) {
  with_readonly(path, fn(connection) {
    use version <- result.try(schema_version(connection, path, "auth"))
    case version {
      1 -> load_auth_v1(connection, path, now)
      version if version >= 2 && version <= 9 ->
        load_auth_current(connection, path, now)
      other -> Error(UnsupportedSchema("auth", other))
    }
  })
}

fn load_auth_v1(
  connection: Connection,
  path: String,
  now: Int,
) -> Result(#(List(SourceUser), List(SourceToken), List(acl.Rule)), Error) {
  use users <- result.try(
    sqlight.query(
      "SELECT user, pass, role FROM user WHERE user <> '*' ORDER BY user",
      on: connection,
      with: [],
      expecting: {
        use username <- decode.field(0, decode.string)
        use password_hash <- decode.field(1, decode.string)
        use role <- decode.field(2, decode.string)
        decode.success(#(username, password_hash, role))
      },
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  use normal_users <- result.try(
    list.try_map(users, fn(row) {
      normalise_user(
        "ntfy_" <> string.slice(security_token.digest(row.0), 0, 20),
        row.0,
        row.1,
        row.2,
        now,
      )
    }),
  )
  use raw_rules <- result.try(
    sqlight.query(
      "SELECT user, topic, read, write FROM access ORDER BY user, topic",
      on: connection,
      with: [],
      expecting: rule_decoder(),
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  use rules <- result.try(normalise_rules(raw_rules))
  Ok(#(normal_users, [], rules))
}

fn load_auth_current(
  connection: Connection,
  path: String,
  now: Int,
) -> Result(#(List(SourceUser), List(SourceToken), List(acl.Rule)), Error) {
  use users <- result.try(
    sqlight.query(
      "SELECT id, user, pass, role, created FROM user WHERE role <> 'anonymous' AND deleted IS NULL ORDER BY user",
      on: connection,
      with: [],
      expecting: {
        use id <- decode.field(0, decode.string)
        use username <- decode.field(1, decode.string)
        use password_hash <- decode.field(2, decode.string)
        use role <- decode.field(3, decode.string)
        use created <- decode.field(4, decode.int)
        decode.success(#(id, username, password_hash, role, created))
      },
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  use normal_users <- result.try(
    list.try_map(users, fn(row) {
      normalise_user(row.0, row.1, row.2, row.3, row.4)
    }),
  )
  use tokens <- result.try(
    sqlight.query(
      "SELECT user_id, token, label, last_access, expires FROM user_token ORDER BY user_id, token",
      on: connection,
      with: [],
      expecting: {
        use user_id <- decode.field(0, decode.string)
        use raw <- decode.field(1, decode.string)
        use label <- decode.field(2, decode.string)
        use last_access <- decode.field(3, decode.int)
        use expires <- decode.field(4, decode.int)
        decode.success(SourceToken(
          user_id:,
          raw:,
          label:,
          created_at: case last_access > 0 {
            True -> last_access
            False -> now
          },
          expires: positive(expires),
          last_access: positive(last_access),
        ))
      },
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  use raw_rules <- result.try(
    sqlight.query(
      "SELECT u.user, a.topic, a.read, a.write FROM user_access a JOIN user u ON u.id = a.user_id ORDER BY u.user, a.topic",
      on: connection,
      with: [],
      expecting: rule_decoder(),
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  use rules <- result.try(normalise_rules(raw_rules))
  Ok(#(normal_users, tokens, rules))
}

fn normalise_user(
  id: String,
  username: String,
  password_hash: String,
  role: String,
  created_at: Int,
) -> Result(SourceUser, Error) {
  use parsed_role <- result.try(case role {
    "admin" -> Ok(acl.Admin)
    "user" -> Ok(acl.User)
    _ -> Error(InvalidSource("invalid role for ntfy user " <> username))
  })
  use _ <- result.try(case valid_username(username) {
    True -> Ok(Nil)
    False -> Error(InvalidSource("invalid ntfy username: " <> username))
  })
  use _ <- result.try(case valid_bcrypt(password_hash) {
    True -> Ok(Nil)
    False ->
      Error(InvalidSource("invalid bcrypt hash for ntfy user " <> username))
  })
  Ok(SourceUser(id:, username:, role: parsed_role, password_hash:, created_at:))
}

fn rule_decoder() -> decode.Decoder(RawRule) {
  use username <- decode.field(0, decode.string)
  use pattern <- decode.field(1, decode.string)
  use read <- decode.field(2, decode.int)
  use write <- decode.field(3, decode.int)
  decode.success(RawRule(username:, pattern:, read:, write:))
}

type RawRule {
  RawRule(username: String, pattern: String, read: Int, write: Int)
}

fn normalise_rules(rows: List(RawRule)) -> Result(List(acl.Rule), Error) {
  list.try_map(rows, fn(row) {
    let pattern =
      row.pattern
      |> string.replace("\\_", "_")
      |> string.replace("%", "*")
    case
      valid_pattern(pattern),
      row.username == "*" || valid_username(row.username)
    {
      True, True ->
        Ok(acl.Rule(
          username: row.username,
          topic_pattern: pattern,
          permission: identity.permission_from_bits(
            row.read != 0,
            row.write != 0,
          ),
        ))
      _, _ -> Error(InvalidSource("invalid ACL entry in ntfy auth database"))
    }
  })
}

fn load_webpush(path: String) -> Result(List(SourcePush), Error) {
  with_readonly(path, fn(connection) {
    use pushes <- result.try(
      sqlight.query(
        "SELECT id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, updated_at FROM subscription ORDER BY id",
        on: connection,
        with: [],
        expecting: {
          use id <- decode.field(0, decode.string)
          use endpoint <- decode.field(1, decode.string)
          use auth <- decode.field(2, decode.string)
          use p256dh <- decode.field(3, decode.string)
          use user_id <- decode.field(4, decode.string)
          use subscriber_ip <- decode.field(5, decode.string)
          use updated_at <- decode.field(6, decode.int)
          decode.success(
            SourcePush(
              id:,
              endpoint:,
              auth:,
              p256dh:,
              user_id: nonempty(user_id),
              subscriber_ip:,
              updated_at:,
              topics: [],
            ),
          )
        },
      )
      |> result.map_error(fn(error) { source_sql_error(path, error) }),
    )
    list.try_map(pushes, fn(push) {
      use topics <- result.try(
        sqlight.query(
          "SELECT topic FROM subscription_topic WHERE subscription_id = ? ORDER BY topic",
          on: connection,
          with: [sqlight.text(push.id)],
          expecting: {
            use topic <- decode.field(0, decode.string)
            decode.success(topic)
          },
        )
        |> result.map_error(fn(error) { source_sql_error(path, error) }),
      )
      let candidate =
        webpush.NewSubscription(
          id: push.id,
          endpoint: push.endpoint,
          auth: push.auth,
          p256dh: push.p256dh,
          topics:,
          user_id: push.user_id,
          subscriber_ip: push.subscriber_ip,
          now: push.updated_at,
        )
      webpush.validate(candidate)
      |> result.map(fn(_) { SourcePush(..push, topics:) })
      |> result.map_error(fn(_) {
        InvalidSource("invalid ntfy Web Push subscription")
      })
    })
  })
}

fn schema_version(
  connection: Connection,
  path: String,
  store: String,
) -> Result(Int, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT version FROM schemaVersion WHERE id = 1",
      on: connection,
      with: [],
      expecting: {
        use version <- decode.field(0, decode.int)
        decode.success(version)
      },
    )
    |> result.map_error(fn(error) { source_sql_error(path, error) }),
  )
  case rows {
    [version] -> Ok(version)
    _ -> Error(InvalidSource(store <> " schema version is missing"))
  }
}

fn with_readonly(
  path: String,
  operation: fn(Connection) -> Result(a, Error),
) -> Result(a, Error) {
  case sqlight.open("file:" <> path <> "?mode=ro") {
    Error(error) -> Error(source_sql_error(path, error))
    Ok(connection) -> {
      let outcome = operation(connection)
      let _ = sqlight.close(connection)
      outcome
    }
  }
}

fn load_attachment_data(
  messages: List(SourceMessage),
  directory: Option(String),
) -> Result(List(ReadyMessage), Error) {
  list.try_map(messages, fn(source) {
    case source.local, directory {
      None, _ -> Ok(ReadyMessage(source.value, None))
      Some(_), None ->
        Error(InvalidSource(
          "ntfy cache references local attachments; provide the attachment directory",
        ))
      Some(local), Some(directory) -> {
        let path = directory <> "/" <> local.message_id
        use data <- result.try(
          read_binary_file(path)
          |> result.map_error(fn(detail) { SourceUnavailable(path, detail) }),
        )
        case bit_array.byte_size(data) == local.size {
          True -> Ok(ReadyMessage(source.value, Some(data)))
          False ->
            Error(InvalidSource(
              "ntfy attachment size does not match cache metadata: "
              <> local.message_id,
            ))
        }
      }
    }
  })
}

fn apply_attachments(
  options: Options,
  ready: List(ReadyMessage),
) -> Result(Attached, Error) {
  apply_attachment_loop(
    ready,
    options.destination_attachments,
    options.base_url,
    [],
    [],
    0,
    0,
    0,
  )
}

fn apply_attachment_loop(
  remaining: List(ReadyMessage),
  store: Option(attachment_store.Store),
  base_url: String,
  migrated_messages: List(message.Message),
  new_keys: List(String),
  scanned: Int,
  migrated: Int,
  skipped: Int,
) -> Result(Attached, Error) {
  case remaining {
    [] ->
      Ok(Attached(
        messages: list.reverse(migrated_messages),
        counts: Counts(scanned:, migrated:, skipped:),
        new_keys:,
      ))
    [ReadyMessage(value, None), ..rest] ->
      apply_attachment_loop(
        rest,
        store,
        base_url,
        [value, ..migrated_messages],
        new_keys,
        scanned,
        migrated,
        skipped,
      )
    [ReadyMessage(value, Some(data)), ..rest] ->
      case store, value.attachment {
        None, _ ->
          Error(InvalidSource(
            "a destination attachment backend is required for ntfy attachments",
          ))
        _, None -> Error(InvalidSource("attachment metadata is missing"))
        Some(store), Some(metadata) -> {
          let key = attachment_store.content_key(data)
          use existed <- result.try(case store.head(key) {
            Ok(_) -> Ok(True)
            Error(attachment_store.NotFound) -> Ok(False)
            Error(error) -> Error(AttachmentError(error))
          })
          use stored <- result.try(
            store.put(attachment_store.Upload(
              data:,
              expires: option_positive(metadata.expires),
            ))
            |> result.map_error(AttachmentError),
          )
          let updated =
            message.Message(
              ..value,
              attachment: Some(
                message.Attachment(
                  ..metadata,
                  url: attachment_url(
                    base_url,
                    value.topic,
                    stored.key,
                    metadata.name,
                  ),
                  size: Some(stored.size),
                  expires: Some(stored.expires),
                ),
              ),
            )
          apply_attachment_loop(
            rest,
            Some(store),
            base_url,
            [updated, ..migrated_messages],
            case existed {
              True -> new_keys
              False -> [stored.key, ..new_keys]
            },
            scanned + 1,
            case existed {
              True -> migrated
              False -> migrated + 1
            },
            case existed {
              True -> skipped + 1
              False -> skipped
            },
          )
        }
      }
  }
}

fn attachment_url(
  base_url: String,
  attached_topic: topic.Topic,
  key: String,
  filename: String,
) -> String {
  let base = case string.ends_with(base_url, "/") {
    True -> string.drop_end(base_url, 1)
    False -> base_url
  }
  base
  <> "/file/"
  <> topic.to_string(attached_topic)
  <> "/"
  <> key
  <> "/"
  <> uri.percent_encode(filename)
}

fn rollback_attachments(
  store: Option(attachment_store.Store),
  keys: List(String),
) -> Nil {
  case store {
    None -> Nil
    Some(store) ->
      list.each(keys, fn(key) {
        let _ = store.delete(key)
      })
  }
}

fn prepare_destination(path: String) -> Result(Nil, Error) {
  use _ <- result.try(
    storage_sqlite.prepare(path)
    |> result.map_error(fn(error) {
      DestinationUnavailable("message schema: " <> string.inspect(error))
    }),
  )
  use _ <- result.try(
    identity_sqlite.prepare(path)
    |> result.map_error(fn(error) {
      DestinationUnavailable("identity schema: " <> string.inspect(error))
    }),
  )
  webpush_sqlite.prepare(path)
  |> result.map_error(fn(error) {
    DestinationUnavailable("Web Push schema: " <> string.inspect(error))
  })
}

fn apply_database(
  options: Options,
  loaded: Loaded,
  messages: List(message.Message),
) -> Result(Applied, Error) {
  case sqlight.open(options.destination_file) {
    Error(error) -> Error(destination_sql_error(error))
    Ok(connection) -> {
      let outcome =
        transaction(connection, fn() {
          use _ <- result.try(
            sqlight.exec(
              "CREATE TABLE IF NOT EXISTS ntfy_imports (kind TEXT NOT NULL, source_key TEXT NOT NULL, imported_at INTEGER NOT NULL, PRIMARY KEY(kind, source_key))",
              connection,
            )
            |> result.map_error(destination_sql_error),
          )
          use message_count <- result.try(insert_messages(
            connection,
            messages,
            0,
          ))
          use user_count <- result.try(insert_users(connection, loaded.users, 0))
          use token_count <- result.try(insert_tokens(
            connection,
            loaded.tokens,
            0,
          ))
          use rule_count <- result.try(insert_rules(connection, loaded.rules, 0))
          use push_count <- result.try(insert_pushes(
            connection,
            loaded.pushes,
            0,
          ))
          use _ <- result.try(case loaded.auth_present {
            False -> Ok(Nil)
            True -> mark_setup_complete(connection, options.default_access)
          })
          Ok(Applied(
            messages: counted(list.length(messages), message_count),
            users: counted(list.length(loaded.users), user_count),
            tokens: counted(list.length(loaded.tokens), token_count),
            rules: counted(list.length(loaded.rules), rule_count),
            pushes: counted(list.length(loaded.pushes), push_count),
          ))
        })
      let _ = sqlight.close(connection)
      outcome
    }
  }
}

fn transaction(
  connection: Connection,
  operation: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection)
    |> result.map_error(destination_sql_error),
  )
  case operation() {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
    Ok(value) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(destination_sql_error(error))
        }
      }
  }
}

fn insert_messages(
  connection: Connection,
  messages: List(message.Message),
  inserted: Int,
) -> Result(Int, Error) {
  case messages {
    [] -> Ok(inserted)
    [value, ..rest] -> {
      let payload = message_json.encode_storage(value) |> json.to_string
      use _ <- result.try(
        sqlight.query(
          "INSERT OR IGNORE INTO messages(id, topic, time, expires, scheduled, sequence_id, payload) VALUES (?, ?, ?, ?, ?, ?, ?)",
          on: connection,
          with: [
            sqlight.text(value.id),
            sqlight.text(topic.to_string(value.topic)),
            sqlight.int(value.time),
            sqlight.nullable(sqlight.int, value.expires),
            sqlight.bool(value.scheduled),
            sqlight.nullable(sqlight.text, value.sequence_id),
            sqlight.text(payload),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(destination_sql_error),
      )
      use changed <- result.try(changes(connection))
      use _ <- result.try(case changed {
        0 -> verify_existing_message(connection, value.id, payload)
        _ ->
          sqlight.query(
            "INSERT INTO event_log(message_id, event, topic, time, payload) VALUES (?, ?, ?, ?, ?)",
            on: connection,
            with: [
              sqlight.text(value.id),
              sqlight.text(message.event_to_string(value.event)),
              sqlight.text(topic.to_string(value.topic)),
              sqlight.int(value.time),
              sqlight.text(payload),
            ],
            expecting: decode.dynamic,
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(destination_sql_error)
      })
      insert_messages(connection, rest, inserted + changed)
    }
  }
}

fn verify_existing_message(
  connection: Connection,
  id: String,
  payload: String,
) -> Result(Nil, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT payload FROM messages WHERE id = ?",
      on: connection,
      with: [sqlight.text(id)],
      expecting: {
        use existing <- decode.field(0, decode.string)
        decode.success(existing)
      },
    )
    |> result.map_error(destination_sql_error),
  )
  case rows {
    [existing] if existing == payload -> Ok(Nil)
    [_] ->
      Error(DestinationUnavailable(
        "message ID conflict with different payload: " <> id,
      ))
    _ -> Error(DestinationUnavailable("message conflict could not be verified"))
  }
}

fn insert_users(
  connection: Connection,
  users: List(SourceUser),
  inserted: Int,
) -> Result(Int, Error) {
  case users {
    [] -> Ok(inserted)
    [user, ..rest] -> {
      use _ <- result.try(
        sqlight.query(
          "INSERT OR IGNORE INTO users(id, username, role, password_hash, created_at) VALUES (?, ?, ?, ?, ?)",
          on: connection,
          with: [
            sqlight.text(user.id),
            sqlight.text(user.username),
            sqlight.text(role_string(user.role)),
            sqlight.text(user.password_hash),
            sqlight.int(user.created_at),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(destination_sql_error),
      )
      use changed <- result.try(changes(connection))
      use _ <- result.try(case changed {
        0 -> verify_existing_user(connection, user)
        _ -> Ok(Nil)
      })
      insert_users(connection, rest, inserted + changed)
    }
  }
}

fn insert_tokens(
  connection: Connection,
  tokens: List(SourceToken),
  inserted: Int,
) -> Result(Int, Error) {
  case tokens {
    [] -> Ok(inserted)
    [token, ..rest] -> {
      let digest = security_token.digest(token.raw)
      use _ <- result.try(
        sqlight.query(
          "INSERT OR IGNORE INTO access_tokens(id, user_id, token_hash, token_prefix, label, created_at, expires) VALUES (?, ?, ?, ?, ?, ?, ?)",
          on: connection,
          with: [
            sqlight.text("ntfy_" <> string.slice(digest, 0, 24)),
            sqlight.text(token.user_id),
            sqlight.text(digest),
            sqlight.text(string.slice(token.raw, 0, 8)),
            sqlight.text(token.label),
            sqlight.int(token.created_at),
            sqlight.nullable(sqlight.int, token.expires),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(destination_sql_error),
      )
      use changed <- result.try(changes(connection))
      use _ <- result.try(case changed {
        0 -> verify_existing_token(connection, token, digest)
        _ -> Ok(Nil)
      })
      use _ <- result.try(record_token_last_access(
        connection,
        digest,
        token.last_access,
      ))
      insert_tokens(connection, rest, inserted + changed)
    }
  }
}

fn record_token_last_access(
  connection: Connection,
  digest: String,
  last_access: Option(Int),
) -> Result(Nil, Error) {
  case last_access {
    None -> Ok(Nil)
    Some(last_access) ->
      sqlight.query(
        "INSERT INTO access_token_activity(token_id, last_access) SELECT id, ? FROM access_tokens WHERE token_hash = ? ON CONFLICT(token_id) DO UPDATE SET last_access = MAX(access_token_activity.last_access, excluded.last_access)",
        on: connection,
        with: [sqlight.int(last_access), sqlight.text(digest)],
        expecting: decode.dynamic,
      )
      |> result.map(fn(_) { Nil })
      |> result.map_error(destination_sql_error)
  }
}

fn insert_rules(
  connection: Connection,
  rules: List(acl.Rule),
  inserted: Int,
) -> Result(Int, Error) {
  case rules {
    [] -> Ok(inserted)
    [acl.Rule(username:, topic_pattern:, permission:), ..rest] -> {
      let #(read, write) = identity.permission_bits(permission)
      use _ <- result.try(
        sqlight.query(
          "INSERT OR IGNORE INTO acl_rules(username, topic_pattern, readable, writable) VALUES (?, ?, ?, ?)",
          on: connection,
          with: [
            sqlight.text(username),
            sqlight.text(topic_pattern),
            sqlight.bool(read),
            sqlight.bool(write),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(destination_sql_error),
      )
      use changed <- result.try(changes(connection))
      use _ <- result.try(case changed {
        0 ->
          verify_existing_rule(connection, username, topic_pattern, read, write)
        _ -> Ok(Nil)
      })
      insert_rules(connection, rest, inserted + changed)
    }
  }
}

fn insert_pushes(
  connection: Connection,
  pushes: List(SourcePush),
  inserted: Int,
) -> Result(Int, Error) {
  case pushes {
    [] -> Ok(inserted)
    [push, ..rest] -> {
      use _ <- result.try(
        sqlight.query(
          "INSERT OR IGNORE INTO webpush_subscriptions(id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          on: connection,
          with: [
            sqlight.text(push.id),
            sqlight.text(push.endpoint),
            sqlight.text(push.auth),
            sqlight.text(push.p256dh),
            sqlight.text(push.user_id |> option.unwrap("")),
            sqlight.text(push.subscriber_ip),
            sqlight.int(push.updated_at),
            sqlight.int(push.updated_at),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(destination_sql_error),
      )
      use changed <- result.try(changes(connection))
      use _ <- result.try(case changed {
        0 -> verify_existing_push(connection, push)
        _ ->
          list.try_each(push.topics, fn(value) {
            sqlight.query(
              "INSERT INTO webpush_topics(subscription_id, topic) VALUES (?, ?)",
              on: connection,
              with: [sqlight.text(push.id), sqlight.text(value)],
              expecting: decode.dynamic,
            )
            |> result.map(fn(_) { Nil })
            |> result.map_error(destination_sql_error)
          })
      })
      insert_pushes(connection, rest, inserted + changed)
    }
  }
}

fn verify_existing_user(
  connection: Connection,
  source: SourceUser,
) -> Result(Nil, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT id, username, role, password_hash, created_at FROM users WHERE id = ? OR username = ?",
      on: connection,
      with: [sqlight.text(source.id), sqlight.text(source.username)],
      expecting: {
        use id <- decode.field(0, decode.string)
        use username <- decode.field(1, decode.string)
        use role <- decode.field(2, decode.string)
        use password_hash <- decode.field(3, decode.string)
        use created_at <- decode.field(4, decode.int)
        decode.success(#(id, username, role, password_hash, created_at))
      },
    )
    |> result.map_error(destination_sql_error),
  )
  case rows {
    [existing] -> {
      let upgraded =
        password.valid_legacy_hash(source.password_hash)
        && string.starts_with(existing.3, "$argon2id$")
      case
        existing.0 == source.id,
        existing.1 == source.username,
        existing.2 == role_string(source.role),
        existing.4 == source.created_at,
        existing.3 == source.password_hash || upgraded
      {
        True, True, True, True, True -> Ok(Nil)
        _, _, _, _, _ ->
          Error(DestinationUnavailable(
            "user conflict with different data: " <> source.username,
          ))
      }
    }
    _ ->
      Error(DestinationUnavailable(
        "user uniqueness conflict could not be verified: " <> source.username,
      ))
  }
}

fn verify_existing_token(
  connection: Connection,
  source: SourceToken,
  digest: String,
) -> Result(Nil, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT user_id, token_prefix, label, created_at, expires FROM access_tokens WHERE token_hash = ?",
      on: connection,
      with: [sqlight.text(digest)],
      expecting: {
        use user_id <- decode.field(0, decode.string)
        use prefix <- decode.field(1, decode.string)
        use label <- decode.field(2, decode.string)
        use created_at <- decode.field(3, decode.int)
        use expires <- decode.field(4, decode.optional(decode.int))
        decode.success(#(user_id, prefix, label, created_at, expires))
      },
    )
    |> result.map_error(destination_sql_error),
  )
  let expected_prefix = string.slice(source.raw, 0, 8)
  case rows {
    [existing] ->
      case
        existing.0 == source.user_id,
        existing.1 == expected_prefix,
        existing.2 == source.label,
        existing.3 == source.created_at,
        existing.4 == source.expires
      {
        True, True, True, True, True -> Ok(Nil)
        _, _, _, _, _ ->
          Error(DestinationUnavailable("token conflict with different data"))
      }
    _ -> Error(DestinationUnavailable("token conflict with different data"))
  }
}

fn verify_existing_rule(
  connection: Connection,
  username: String,
  pattern: String,
  readable: Bool,
  writable: Bool,
) -> Result(Nil, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT readable, writable FROM acl_rules WHERE username = ? AND topic_pattern = ?",
      on: connection,
      with: [sqlight.text(username), sqlight.text(pattern)],
      expecting: {
        use read <- decode.field(0, decode.int)
        use write <- decode.field(1, decode.int)
        decode.success(#(read != 0, write != 0))
      },
    )
    |> result.map_error(destination_sql_error),
  )
  case rows {
    [#(read, write)] if read == readable && write == writable -> Ok(Nil)
    _ ->
      Error(DestinationUnavailable(
        "ACL conflict with different data: " <> username <> ":" <> pattern,
      ))
  }
}

fn verify_existing_push(
  connection: Connection,
  source: SourcePush,
) -> Result(Nil, Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT id, key_auth, key_p256dh, user_id, subscriber_ip, updated_at FROM webpush_subscriptions WHERE id = ? OR endpoint = ?",
      on: connection,
      with: [sqlight.text(source.id), sqlight.text(source.endpoint)],
      expecting: {
        use id <- decode.field(0, decode.string)
        use auth <- decode.field(1, decode.string)
        use p256dh <- decode.field(2, decode.string)
        use user_id <- decode.field(3, decode.string)
        use subscriber_ip <- decode.field(4, decode.string)
        use updated_at <- decode.field(5, decode.int)
        decode.success(#(id, auth, p256dh, user_id, subscriber_ip, updated_at))
      },
    )
    |> result.map_error(destination_sql_error),
  )
  let expected_user_id = option.unwrap(source.user_id, "")
  use _ <- result.try(case rows {
    [existing] ->
      case
        existing.0 == source.id,
        existing.1 == source.auth,
        existing.2 == source.p256dh,
        existing.3 == expected_user_id,
        existing.4 == source.subscriber_ip,
        existing.5 == source.updated_at
      {
        True, True, True, True, True, True -> Ok(Nil)
        _, _, _, _, _, _ ->
          Error(DestinationUnavailable(
            "Web Push subscription conflict with different data: " <> source.id,
          ))
      }
    _ ->
      Error(DestinationUnavailable(
        "Web Push subscription conflict with different data: " <> source.id,
      ))
  })
  use topics <- result.try(
    sqlight.query(
      "SELECT topic FROM webpush_topics WHERE subscription_id = ? ORDER BY topic",
      on: connection,
      with: [sqlight.text(source.id)],
      expecting: {
        use topic <- decode.field(0, decode.string)
        decode.success(topic)
      },
    )
    |> result.map_error(destination_sql_error),
  )
  case topics == source.topics {
    True -> Ok(Nil)
    False ->
      Error(DestinationUnavailable(
        "Web Push topic conflict with different data: " <> source.id,
      ))
  }
}

fn mark_setup_complete(
  connection: Connection,
  permission: acl.Permission,
) -> Result(Nil, Error) {
  let #(read, write) = identity.permission_bits(permission)
  use _ <- result.try(
    sqlight.query(
      "UPDATE auth_state SET setup_complete = 1, anonymous_read = ?, anonymous_write = ? WHERE id = 1",
      on: connection,
      with: [sqlight.bool(read), sqlight.bool(write)],
      expecting: decode.dynamic,
    )
    |> result.map_error(destination_sql_error),
  )
  sqlight.query(
    "DELETE FROM setup_challenge",
    on: connection,
    with: [],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(destination_sql_error)
}

fn changes(connection: Connection) -> Result(Int, Error) {
  use rows <- result.try(
    sqlight.query("SELECT changes()", on: connection, with: [], expecting: {
      use count <- decode.field(0, decode.int)
      decode.success(count)
    })
    |> result.map_error(destination_sql_error),
  )
  case rows {
    [count] -> Ok(count)
    _ -> Error(DestinationUnavailable("SQLite changes() returned no row"))
  }
}

fn counted(scanned: Int, migrated: Int) -> Counts {
  Counts(scanned:, migrated:, skipped: scanned - migrated)
}

fn count_ready_attachments(messages: List(ReadyMessage)) -> Int {
  list.fold(messages, 0, fn(count, item) {
    case item.attachment_data {
      Some(_) -> count + 1
      None -> count
    }
  })
}

fn split_tags(value: String) -> List(String) {
  case value {
    "" -> []
    value -> string.split(value, ",")
  }
}

fn nonempty(value: String) -> Option(String) {
  case string.is_empty(value) {
    True -> None
    False -> Some(value)
  }
}

fn positive(value: Int) -> Option(Int) {
  case value > 0 {
    True -> Some(value)
    False -> None
  }
}

fn option_positive(value: Option(Int)) -> Int {
  value |> option.unwrap(0)
}

fn option_is_some(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

fn valid_username(username: String) -> Bool {
  let allowed =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.@"
  string.length(username) >= 1
  && string.length(username) <= 64
  && username != "everyone"
  && username != "*"
  && username
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains(allowed, character) })
}

fn valid_pattern(pattern: String) -> Bool {
  let allowed =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_*"
  string.length(pattern) >= 1
  && string.length(pattern) <= 64
  && pattern
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains(allowed, character) })
}

fn valid_bcrypt(hash: String) -> Bool {
  password.valid_legacy_hash(hash)
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.Admin -> "admin"
    acl.User -> "user"
  }
}

fn source_sql_error(path: String, error: sqlight.Error) -> Error {
  let sqlight.SqlightError(message:, ..) = error
  SourceUnavailable(path, message)
}

fn destination_sql_error(error: sqlight.Error) -> Error {
  let sqlight.SqlightError(message:, ..) = error
  DestinationUnavailable(message)
}

pub fn error_message(error: Error) -> String {
  case error {
    SourceUnavailable(path, detail) ->
      "unable to read ntfy source " <> path <> ": " <> detail
    UnsupportedSchema(store, version) ->
      "unsupported ntfy "
      <> store
      <> " schema version "
      <> int.to_string(version)
      <> "; open it once with ntfy v2.27.0 before retrying"
    InvalidSource(detail) -> "invalid ntfy source: " <> detail
    SourceChanged(detail) -> "ntfy source changed during migration: " <> detail
    DestinationUnavailable(detail) ->
      "unable to migrate Notify destination: " <> detail
    AttachmentError(error) ->
      "unable to migrate attachment: " <> string.inspect(error)
  }
}

@external(erlang, "notify_ffi", "file_sha256")
fn file_sha256(path: String) -> Result(String, String)

@external(erlang, "notify_ffi", "path_exists")
fn ffi_path_exists(path: String) -> Bool

@external(erlang, "notify_ffi", "read_binary_file")
fn read_binary_file(path: String) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "read_file")
fn read_text_file(path: String) -> Result(String, Nil)
