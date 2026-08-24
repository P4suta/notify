import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Language {
  English
  Japanese
}

pub type Connection {
  Offline
  Connecting
  Live
  Reconnecting
}

pub type Notification {
  Notification(
    id: String,
    topic: String,
    title: String,
    body: String,
    time: Int,
    priority: Int,
    sequence_id: String,
  )
}

pub type Model {
  Model(
    language: Language,
    topic: String,
    topic_input: String,
    connection: Connection,
    notifications: List(Notification),
    filter: String,
    message: String,
    title: String,
    priority: String,
    tags: String,
    publish_status: String,
    csrf: String,
    username: String,
    login_open: Bool,
    login_username: String,
    login_password: String,
    login_status: String,
    admin_open: Bool,
    system_health: String,
    users: List(String),
    access_rules: List(String),
    delivery_jobs: List(String),
    attachments: List(String),
    admin_status: String,
    issued_token: String,
    admin_username: String,
    admin_password: String,
    admin_role: String,
    token_label: String,
    token_id: String,
    acl_pattern: String,
    acl_permission: String,
    attachment_key: String,
    push_available: Bool,
    push_enabled: Bool,
    push_status: String,
  )
}

pub type Message {
  UserChangedLanguage
  UserOpenedTopic(String)
  UserChangedTopicInput(String)
  UserSubmittedTopic
  UserChangedFilter(String)
  UserChangedMessage(String)
  UserChangedTitle(String)
  UserChangedPriority(String)
  UserChangedTags(String)
  UserSubmittedPublish
  UserOpenedLogin
  UserClosedLogin
  UserChangedLoginUsername(String)
  UserChangedLoginPassword(String)
  UserSubmittedLogin
  UserOpenedAdmin
  UserClosedAdmin
  UserChangedAdminUsername(String)
  UserChangedAdminPassword(String)
  UserChangedAdminRole(String)
  UserChangedTokenLabel(String)
  UserChangedTokenId(String)
  UserChangedAclPattern(String)
  UserChangedAclPermission(String)
  UserChangedAttachmentKey(String)
  UserSubmittedCreateUser
  UserSubmittedDeleteUser
  UserSubmittedCreateToken
  UserSubmittedRevokeToken
  UserSubmittedPutAcl
  UserSubmittedDeleteAcl
  UserSubmittedDeleteAttachment
  UserToggledPush
  UserToggledTheme
  ServerLoadedHistory(List(Notification))
  ServerSentNotification(Notification)
  ServerRemovedSequence(topic: String, sequence_id: String)
  ServerChangedConnection(Connection)
  BrowserBootstrapped(String, String)
  ServerLoadedHistoryJson(String)
  ServerSentNotificationJson(String)
  ServerChangedConnectionName(String)
  ServerCompletedPublish(Bool, String)
  ServerRestoredSession(String, String)
  ServerCompletedLogin(Bool, String, String)
  ServerLoadedAdmin(String, String, String, String, String)
  ServerCompletedAdminMutation(Bool, String, String)
  ServerChangedPush(Bool, Bool, String)
}

pub fn initial_model() -> Model {
  Model(
    language: English,
    topic: "",
    topic_input: "",
    connection: Offline,
    notifications: [],
    filter: "",
    message: "",
    title: "",
    priority: "default",
    tags: "",
    publish_status: "",
    csrf: "",
    username: "",
    login_open: False,
    login_username: "",
    login_password: "",
    login_status: "",
    admin_open: False,
    system_health: "—",
    users: [],
    access_rules: [],
    delivery_jobs: [],
    attachments: [],
    admin_status: "",
    issued_token: "",
    admin_username: "",
    admin_password: "",
    admin_role: "user",
    token_label: "",
    token_id: "",
    acl_pattern: "",
    acl_permission: "read",
    attachment_key: "",
    push_available: False,
    push_enabled: False,
    push_status: "",
  )
}

pub fn reduce(model: Model, message: Message) -> Model {
  case message {
    UserChangedLanguage ->
      Model(..model, language: case model.language {
        English -> Japanese
        Japanese -> English
      })

    UserOpenedTopic(topic) ->
      Model(
        ..model,
        topic:,
        topic_input: topic,
        connection: Connecting,
        notifications: [],
        publish_status: "",
      )

    UserChangedTopicInput(topic_input) -> Model(..model, topic_input:)
    UserSubmittedTopic -> model
    UserChangedFilter(filter) -> Model(..model, filter:)
    UserChangedMessage(message) -> Model(..model, message:)
    UserChangedTitle(title) -> Model(..model, title:)
    UserChangedPriority(priority) -> Model(..model, priority:)
    UserChangedTags(tags) -> Model(..model, tags:)
    UserSubmittedPublish -> model
    UserOpenedLogin -> Model(..model, login_open: True, login_status: "")
    UserClosedLogin ->
      Model(..model, login_open: False, login_password: "", login_status: "")
    UserChangedLoginUsername(login_username) -> Model(..model, login_username:)
    UserChangedLoginPassword(login_password) -> Model(..model, login_password:)
    UserSubmittedLogin -> model
    UserOpenedAdmin -> Model(..model, admin_open: True)
    UserClosedAdmin -> Model(..model, admin_open: False)
    UserChangedAdminUsername(admin_username) -> Model(..model, admin_username:)
    UserChangedAdminPassword(admin_password) -> Model(..model, admin_password:)
    UserChangedAdminRole(admin_role) -> Model(..model, admin_role:)
    UserChangedTokenLabel(token_label) -> Model(..model, token_label:)
    UserChangedTokenId(token_id) -> Model(..model, token_id:)
    UserChangedAclPattern(acl_pattern) -> Model(..model, acl_pattern:)
    UserChangedAclPermission(acl_permission) -> Model(..model, acl_permission:)
    UserChangedAttachmentKey(attachment_key) -> Model(..model, attachment_key:)
    UserSubmittedCreateUser
    | UserSubmittedDeleteUser
    | UserSubmittedCreateToken
    | UserSubmittedRevokeToken
    | UserSubmittedPutAcl
    | UserSubmittedDeleteAcl
    | UserSubmittedDeleteAttachment -> model
    UserToggledPush | UserToggledTheme -> model
    ServerLoadedHistory(notifications) ->
      Model(
        ..model,
        notifications: deduplicate(notifications),
        connection: Live,
      )
    ServerSentNotification(notification) ->
      Model(
        ..model,
        notifications: upsert_notification(model.notifications, notification),
      )
    ServerRemovedSequence(topic, sequence_id) ->
      Model(
        ..model,
        notifications: remove_sequence(model.notifications, topic, sequence_id),
      )
    ServerChangedConnection(connection) -> Model(..model, connection:)
    BrowserBootstrapped(_, _) -> model
    ServerLoadedHistoryJson(_) | ServerSentNotificationJson(_) -> model
    ServerChangedConnectionName(_) -> model
    ServerCompletedPublish(success, status) ->
      case success {
        True ->
          Model(
            ..model,
            message: "",
            title: "",
            tags: "",
            publish_status: status,
          )
        False -> Model(..model, publish_status: status)
      }
    ServerRestoredSession(username, csrf) -> Model(..model, username:, csrf:)
    ServerCompletedLogin(success, username, detail) ->
      case success {
        True ->
          Model(
            ..model,
            username:,
            csrf: detail,
            login_open: False,
            login_password: "",
            login_status: "",
          )
        False -> Model(..model, login_status: detail, login_password: "")
      }
    ServerLoadedAdmin(
      system_health,
      users,
      access_rules,
      delivery_jobs,
      attachments,
    ) ->
      Model(
        ..model,
        system_health:,
        users: lines(users),
        access_rules: lines(access_rules),
        delivery_jobs: lines(delivery_jobs),
        attachments: lines(attachments),
      )
    ServerCompletedAdminMutation(success, admin_status, issued_token) ->
      Model(
        ..model,
        admin_status:,
        issued_token: case success {
          True -> issued_token
          False -> ""
        },
        admin_password: "",
      )
    ServerChangedPush(available, enabled, status) ->
      Model(
        ..model,
        push_available: available,
        push_enabled: enabled,
        push_status: status,
      )
  }
}

fn lines(value: String) -> List(String) {
  case string.trim(value) {
    "" -> []
    value -> string.split(value, "\n")
  }
}

pub fn visible_notifications(model: Model) -> List(Notification) {
  let needle = model.filter |> string.trim |> string.lowercase
  case needle {
    "" -> model.notifications
    _ ->
      list.filter(model.notifications, fn(notification) {
        notification_search_text(notification)
        |> string.lowercase
        |> string.contains(needle)
      })
  }
}

fn notification_search_text(notification: Notification) -> String {
  [
    notification.id,
    notification.topic,
    notification.title,
    notification.body,
    int.to_string(notification.priority),
  ]
  |> string.join(" ")
}

fn append_unseen(
  notifications: List(Notification),
  notification: Notification,
) -> List(Notification) {
  case list.any(notifications, fn(current) { current.id == notification.id }) {
    True -> notifications
    False -> list.append(notifications, [notification])
  }
}

fn upsert_notification(
  notifications: List(Notification),
  notification: Notification,
) -> List(Notification) {
  let without_previous_sequence = case notification.sequence_id {
    "" -> notifications
    sequence_id ->
      remove_sequence(notifications, notification.topic, sequence_id)
  }
  append_unseen(without_previous_sequence, notification)
}

fn remove_sequence(
  notifications: List(Notification),
  topic: String,
  sequence_id: String,
) -> List(Notification) {
  list.filter(notifications, fn(notification) {
    notification.topic != topic || notification.sequence_id != sequence_id
  })
}

fn deduplicate(notifications: List(Notification)) -> List(Notification) {
  list.fold(notifications, [], upsert_notification)
}

type WireNotification {
  WireNotification(
    event: String,
    id: String,
    topic: String,
    title: String,
    body: String,
    time: Int,
    priority: Int,
    sequence_id: String,
  )
}

type WireChange {
  AddNotification(Notification)
  RemoveSequence(topic: String, sequence_id: String)
  IgnoreWireEvent
}

@external(javascript, "./notify_web_ffi.mjs", "bootstrap")
fn browser_bootstrap(
  on_ready: fn(String, String) -> Nil,
  on_session: fn(String, String) -> Nil,
  on_push: fn(Bool, Bool, String) -> Nil,
  on_notification: fn(String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "open_topic")
fn browser_open_topic(
  topic: String,
  on_history: fn(String) -> Nil,
  on_notification: fn(String) -> Nil,
  on_connection: fn(String) -> Nil,
  on_push: fn(Bool, Bool, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "publish")
fn browser_publish(
  topic: String,
  message: String,
  title: String,
  priority: String,
  tags: String,
  csrf: String,
  on_complete: fn(Bool, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "login")
fn browser_login(
  username: String,
  password: String,
  on_complete: fn(Bool, String, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "load_admin")
fn browser_load_admin(
  on_complete: fn(String, String, String, String, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "admin_mutation")
fn browser_admin_mutation(
  operation: String,
  username: String,
  password: String,
  role: String,
  token_label: String,
  token_id: String,
  topic_pattern: String,
  permission: String,
  attachment_key: String,
  csrf: String,
  on_complete: fn(Bool, String, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "toggle_push")
fn browser_toggle_push(
  topic: String,
  csrf: String,
  on_complete: fn(Bool, Bool, String) -> Nil,
) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "store_language")
fn browser_store_language(language: String) -> Nil

@external(javascript, "./notify_web_ffi.mjs", "toggle_theme")
fn browser_toggle_theme() -> Nil

fn init(_) -> #(Model, Effect(Message)) {
  #(
    initial_model(),
    effect.from(fn(dispatch) {
      browser_bootstrap(
        fn(language, topic) { dispatch(BrowserBootstrapped(language, topic)) },
        fn(username, csrf) { dispatch(ServerRestoredSession(username, csrf)) },
        fn(available, enabled, status) {
          dispatch(ServerChangedPush(available, enabled, status))
        },
        fn(payload) { dispatch(ServerSentNotificationJson(payload)) },
      )
    }),
  )
}

fn application_update(
  model: Model,
  message: Message,
) -> #(Model, Effect(Message)) {
  case message {
    UserSubmittedTopic ->
      case valid_topic(model.topic_input) {
        True -> application_update(model, UserOpenedTopic(model.topic_input))
        False -> #(Model(..model, connection: Offline), effect.none())
      }
    UserOpenedTopic(topic) -> #(
      reduce(model, message),
      open_topic_effect(topic),
    )
    UserSubmittedPublish ->
      case model.topic, string.trim(model.message) {
        "", _ -> #(
          Model(
            ..model,
            publish_status: choose(
              model.language,
              "Choose a topic first.",
              "先にトピックを開いてください。",
            ),
          ),
          effect.none(),
        )
        _, "" -> #(
          Model(
            ..model,
            publish_status: choose(
              model.language,
              "Enter a message.",
              "メッセージを入力してください。",
            ),
          ),
          effect.none(),
        )
        _, _ -> #(
          Model(
            ..model,
            publish_status: choose(model.language, "Sending…", "送信中…"),
          ),
          publish_effect(model),
        )
      }
    UserChangedLanguage -> {
      let next = reduce(model, message)
      #(
        next,
        effect.from(fn(_) {
          browser_store_language(case next.language {
            English -> "en"
            Japanese -> "ja"
          })
        }),
      )
    }
    UserSubmittedLogin -> #(
      Model(
        ..model,
        login_status: choose(model.language, "Signing in…", "ログイン中…"),
      ),
      login_effect(model),
    )
    UserOpenedAdmin -> #(reduce(model, message), admin_effect())
    UserSubmittedCreateUser -> admin_mutation(model, "create_user")
    UserSubmittedDeleteUser -> admin_mutation(model, "delete_user")
    UserSubmittedCreateToken -> admin_mutation(model, "create_token")
    UserSubmittedRevokeToken -> admin_mutation(model, "revoke_token")
    UserSubmittedPutAcl -> admin_mutation(model, "put_acl")
    UserSubmittedDeleteAcl -> admin_mutation(model, "delete_acl")
    UserSubmittedDeleteAttachment -> admin_mutation(model, "delete_attachment")
    ServerCompletedAdminMutation(success, _, _) -> {
      let next = reduce(model, message)
      #(next, case success {
        True -> admin_effect()
        False -> effect.none()
      })
    }
    UserToggledPush -> #(
      Model(..model, push_status: choose(model.language, "Updating…", "更新中…")),
      push_effect(model),
    )
    UserToggledTheme -> #(model, effect.from(fn(_) { browser_toggle_theme() }))
    BrowserBootstrapped(language, topic) -> {
      let configured =
        Model(
          ..model,
          language: case language {
            "ja" -> Japanese
            _ -> English
          },
          topic_input: topic,
        )
      case valid_topic(topic) {
        True -> application_update(configured, UserOpenedTopic(topic))
        False -> #(configured, effect.none())
      }
    }
    ServerLoadedHistoryJson(payload) -> #(
      Model(
        ..model,
        notifications: apply_history(model.notifications, payload),
        connection: Live,
      ),
      effect.none(),
    )
    ServerSentNotificationJson(payload) ->
      case parse_wire_change(payload) {
        AddNotification(notification) -> #(
          reduce(model, ServerSentNotification(notification)),
          effect.none(),
        )
        RemoveSequence(topic, sequence_id) -> #(
          reduce(model, ServerRemovedSequence(topic, sequence_id)),
          effect.none(),
        )
        IgnoreWireEvent -> #(model, effect.none())
      }
    ServerChangedConnectionName(connection) -> #(
      reduce(
        model,
        ServerChangedConnection(case connection {
          "live" -> Live
          "reconnecting" -> Reconnecting
          "connecting" -> Connecting
          _ -> Offline
        }),
      ),
      effect.none(),
    )
    _ -> #(reduce(model, message), effect.none())
  }
}

fn open_topic_effect(topic: String) -> Effect(Message) {
  effect.from(fn(dispatch) {
    browser_open_topic(
      topic,
      fn(payload) { dispatch(ServerLoadedHistoryJson(payload)) },
      fn(payload) { dispatch(ServerSentNotificationJson(payload)) },
      fn(connection) { dispatch(ServerChangedConnectionName(connection)) },
      fn(available, enabled, status) {
        dispatch(ServerChangedPush(available, enabled, status))
      },
    )
  })
}

fn publish_effect(model: Model) -> Effect(Message) {
  effect.from(fn(dispatch) {
    browser_publish(
      model.topic,
      model.message,
      model.title,
      model.priority,
      model.tags,
      model.csrf,
      fn(success, status) { dispatch(ServerCompletedPublish(success, status)) },
    )
  })
}

fn login_effect(model: Model) -> Effect(Message) {
  effect.from(fn(dispatch) {
    browser_login(
      model.login_username,
      model.login_password,
      fn(success, username, detail) {
        dispatch(ServerCompletedLogin(success, username, detail))
      },
    )
  })
}

fn admin_effect() -> Effect(Message) {
  effect.from(fn(dispatch) {
    browser_load_admin(fn(health, users, access_rules, jobs, attachments) {
      dispatch(ServerLoadedAdmin(health, users, access_rules, jobs, attachments))
    })
  })
}

fn admin_mutation(
  model: Model,
  operation: String,
) -> #(Model, Effect(Message)) {
  #(
    Model(
      ..model,
      admin_status: choose(model.language, "Updating…", "更新中…"),
      issued_token: "",
    ),
    effect.from(fn(dispatch) {
      browser_admin_mutation(
        operation,
        model.admin_username,
        model.admin_password,
        model.admin_role,
        model.token_label,
        model.token_id,
        model.acl_pattern,
        model.acl_permission,
        model.attachment_key,
        model.csrf,
        fn(success, status, secret) {
          dispatch(ServerCompletedAdminMutation(success, status, secret))
        },
      )
    }),
  )
}

fn push_effect(model: Model) -> Effect(Message) {
  effect.from(fn(dispatch) {
    browser_toggle_push(model.topic, model.csrf, fn(available, enabled, status) {
      dispatch(ServerChangedPush(available, enabled, status))
    })
  })
}

fn apply_history(
  existing: List(Notification),
  payload: String,
) -> List(Notification) {
  payload
  |> string.split("\n")
  |> list.fold(existing, fn(notifications, payload) {
    case parse_wire_change(payload) {
      AddNotification(notification) ->
        upsert_notification(notifications, notification)
      RemoveSequence(topic, sequence_id) ->
        remove_sequence(notifications, topic, sequence_id)
      IgnoreWireEvent -> notifications
    }
  })
}

fn parse_wire_change(payload: String) -> WireChange {
  case json.parse(payload, wire_notification_decoder()) {
    Ok(WireNotification(
      event: "message",
      id:,
      topic:,
      title:,
      body:,
      time:,
      priority:,
      sequence_id:,
    )) ->
      AddNotification(Notification(
        id:,
        topic:,
        title:,
        body:,
        time:,
        priority:,
        sequence_id:,
      ))
    Ok(WireNotification(event: event_name, topic:, sequence_id:, ..))
      if { event_name == "message_delete" || event_name == "message_clear" }
      && sequence_id != ""
    -> RemoveSequence(topic, sequence_id)
    _ -> IgnoreWireEvent
  }
}

fn wire_notification_decoder() -> decode.Decoder(WireNotification) {
  use event_name <- decode.optional_field("event", "message", decode.string)
  use id <- decode.field("id", decode.string)
  use topic <- decode.field("topic", decode.string)
  use title <- decode.optional_field("title", "", decode.string)
  use body <- decode.optional_field("message", "", decode.string)
  use time <- decode.field("time", decode.int)
  use priority <- decode.optional_field("priority", 3, decode.int)
  use sequence_id <- decode.optional_field("sequence_id", "", decode.string)
  decode.success(WireNotification(
    event: event_name,
    id:,
    topic:,
    title:,
    body:,
    time:,
    priority:,
    sequence_id:,
  ))
}

fn choose(language: Language, english: String, japanese: String) -> String {
  case language {
    English -> english
    Japanese -> japanese
  }
}

fn valid_topic(topic: String) -> Bool {
  let length = string.length(topic)
  length > 0
  && length <= 64
  && list.all(string.to_graphemes(topic), fn(character) {
    string.contains(
      "-_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      character,
    )
  })
}

fn text(language: Language, key: String) -> String {
  case language, key {
    English, "topics" -> "Topics"
    Japanese, "topics" -> "トピック"
    English, "topic" -> "Topic"
    Japanese, "topic" -> "トピック"
    English, "open" -> "Open"
    Japanese, "open" -> "開く"
    English, "timeline" -> "Timeline"
    Japanese, "timeline" -> "タイムライン"
    English, "filter" -> "Filter messages"
    Japanese, "filter" -> "メッセージを絞り込む"
    English, "message" -> "Message"
    Japanese, "message" -> "メッセージ"
    English, "title" -> "Title"
    Japanese, "title" -> "タイトル"
    English, "priority" -> "Priority"
    Japanese, "priority" -> "優先度"
    English, "tags" -> "Tags"
    Japanese, "tags" -> "タグ"
    English, "publish" -> "Publish"
    Japanese, "publish" -> "送信"
    English, "attachment" -> "Attachment"
    Japanese, "attachment" -> "添付"
    English, "enable_notifications" -> "Enable notifications"
    Japanese, "enable_notifications" -> "通知を有効化"
    English, "disable_notifications" -> "Disable notifications"
    Japanese, "disable_notifications" -> "通知を無効化"
    English, "system" -> "System & access"
    Japanese, "system" -> "システムと権限"
    English, "administration" -> "Administration"
    Japanese, "administration" -> "管理"
    English, "health" -> "Health"
    Japanese, "health" -> "稼働状態"
    English, "users" -> "Users"
    Japanese, "users" -> "ユーザー"
    English, "access" -> "Access rules"
    Japanese, "access" -> "アクセスルール"
    English, "delivery_jobs" -> "Delivery failures & jobs"
    Japanese, "delivery_jobs" -> "配信失敗とジョブ"
    English, "attachments" -> "Attachments"
    Japanese, "attachments" -> "添付"
    English, "role" -> "Role"
    Japanese, "role" -> "ロール"
    English, "label" -> "Label"
    Japanese, "label" -> "ラベル"
    English, "token_id" -> "Token ID"
    Japanese, "token_id" -> "トークンID"
    English, "topic_pattern" -> "Topic pattern"
    Japanese, "topic_pattern" -> "トピックパターン"
    English, "permission" -> "Permission"
    Japanese, "permission" -> "権限"
    English, "create_user" -> "Create user"
    Japanese, "create_user" -> "ユーザー作成"
    English, "delete_user" -> "Delete user"
    Japanese, "delete_user" -> "ユーザー削除"
    English, "create_token" -> "Create token"
    Japanese, "create_token" -> "トークン作成"
    English, "revoke_token" -> "Revoke token"
    Japanese, "revoke_token" -> "トークン失効"
    English, "save_rule" -> "Save rule"
    Japanese, "save_rule" -> "ルール保存"
    English, "delete_rule" -> "Delete rule"
    Japanese, "delete_rule" -> "ルール削除"
    English, "attachment_key" -> "Attachment key"
    Japanese, "attachment_key" -> "添付キー"
    English, "delete_attachment" -> "Delete attachment"
    Japanese, "delete_attachment" -> "添付削除"
    English, "issued_token" -> "Copy this token now; it will not be shown again"
    Japanese, "issued_token" -> "このトークンは今すぐコピーしてください。再表示されません"
    English, "sign_in" -> "Sign in"
    Japanese, "sign_in" -> "ログイン"
    English, "username" -> "Username"
    Japanese, "username" -> "ユーザー名"
    English, "password" -> "Password"
    Japanese, "password" -> "パスワード"
    _, _ -> key
  }
}

fn connection_text(model: Model) -> String {
  case model.connection, model.language {
    Offline, English -> "Offline"
    Offline, Japanese -> "オフライン"
    Connecting, English -> "Connecting…"
    Connecting, Japanese -> "接続中…"
    Live, English -> "Live"
    Live, Japanese -> "接続中"
    Reconnecting, English -> "Reconnecting…"
    Reconnecting, Japanese -> "再接続中…"
  }
}

fn notification_view(notification: Notification) -> Element(Message) {
  let heading = case notification.title {
    "" -> notification.topic
    title -> title
  }
  html.li([attribute.class("message-card")], [
    html.strong([], [html.text(heading)]),
    html.p([], [html.text(notification.body)]),
    html.small([], [
      html.text(
        int.to_string(notification.time)
        <> " · "
        <> notification.id
        <> " · "
        <> int.to_string(notification.priority),
      ),
    ]),
  ])
}

fn text_item(value: String) -> Element(Message) {
  html.li([], [html.text(value)])
}

fn login_dialog(model: Model) -> Element(Message) {
  html.dialog(
    [
      attribute.attribute("open", case model.login_open {
        True -> ""
        False -> "closed"
      }),
      attribute.hidden(!model.login_open),
      attribute.aria_modal(True),
      attribute.aria_labelledby("login-title"),
    ],
    [
      html.form([event.on_submit(fn(_) { UserSubmittedLogin })], [
        html.div([attribute.class("section-title")], [
          html.h2([attribute.id("login-title")], [
            html.text(text(model.language, "sign_in")),
          ]),
          html.button(
            [
              attribute.class("quiet"),
              attribute.type_("button"),
              attribute.aria_label("Close"),
              event.on_click(UserClosedLogin),
            ],
            [html.text("×")],
          ),
        ]),
        html.label([], [
          html.span([], [html.text(text(model.language, "username"))]),
          html.input([
            attribute.name("username"),
            attribute.autocomplete("username"),
            attribute.required(True),
            attribute.value(model.login_username),
            event.on_input(UserChangedLoginUsername),
          ]),
        ]),
        html.label([], [
          html.span([], [html.text(text(model.language, "password"))]),
          html.input([
            attribute.name("password"),
            attribute.type_("password"),
            attribute.autocomplete("current-password"),
            attribute.required(True),
            attribute.value(model.login_password),
            event.on_input(UserChangedLoginPassword),
          ]),
        ]),
        html.button([attribute.type_("submit")], [
          html.text(text(model.language, "sign_in")),
        ]),
        html.output([attribute.role("status")], [html.text(model.login_status)]),
      ]),
    ],
  )
}

fn admin_text_input(
  label: String,
  value: String,
  input_type: String,
  autocomplete: String,
  required: Bool,
  changed: fn(String) -> Message,
) -> Element(Message) {
  html.label([], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_(input_type),
      attribute.autocomplete(autocomplete),
      attribute.required(required),
      attribute.value(value),
      event.on_input(changed),
    ]),
  ])
}

fn admin_panel(model: Model) -> Element(Message) {
  html.aside(
    [
      attribute.class("admin-panel"),
      attribute.hidden(!model.admin_open),
      attribute.aria_labelledby("admin-title"),
    ],
    [
      html.div([attribute.class("section-title")], [
        html.h2([attribute.id("admin-title")], [
          html.text(text(model.language, "administration")),
        ]),
        html.button(
          [
            attribute.class("quiet"),
            attribute.type_("button"),
            attribute.aria_label("Close"),
            event.on_click(UserClosedAdmin),
          ],
          [html.text("×")],
        ),
      ]),
      html.output([attribute.class("admin-status"), attribute.role("status")], [
        html.text(model.admin_status),
      ]),
      html.div(
        [
          attribute.class("issued-secret"),
          attribute.hidden(model.issued_token == ""),
        ],
        [
          html.strong([], [html.text(text(model.language, "issued_token"))]),
          html.code([], [html.text(model.issued_token)]),
        ],
      ),
      html.section([], [
        html.h3([], [html.text(text(model.language, "health"))]),
        html.pre([], [html.text(model.system_health)]),
      ]),
      html.section([], [
        html.h3([], [html.text(text(model.language, "users"))]),
        html.ul([], list.map(model.users, text_item)),
        html.form(
          [
            attribute.class("admin-form"),
            event.on_submit(fn(_) { UserSubmittedCreateUser }),
          ],
          [
            admin_text_input(
              text(model.language, "username"),
              model.admin_username,
              "text",
              "username",
              True,
              UserChangedAdminUsername,
            ),
            admin_text_input(
              text(model.language, "password"),
              model.admin_password,
              "password",
              "new-password",
              True,
              UserChangedAdminPassword,
            ),
            html.label([], [
              html.span([], [html.text(text(model.language, "role"))]),
              html.select(
                [
                  attribute.value(model.admin_role),
                  event.on_change(UserChangedAdminRole),
                ],
                [
                  html.option([attribute.value("user")], "User"),
                  html.option([attribute.value("admin")], "Admin"),
                ],
              ),
            ]),
            html.button([attribute.type_("submit")], [
              html.text(text(model.language, "create_user")),
            ]),
          ],
        ),
        html.form(
          [
            attribute.class("admin-form compact"),
            event.on_submit(fn(_) { UserSubmittedDeleteUser }),
          ],
          [
            admin_text_input(
              text(model.language, "username"),
              model.admin_username,
              "text",
              "off",
              True,
              UserChangedAdminUsername,
            ),
            html.button([attribute.class("danger"), attribute.type_("submit")], [
              html.text(text(model.language, "delete_user")),
            ]),
          ],
        ),
      ]),
      html.section([], [
        html.h3([], [html.text("Tokens")]),
        html.form(
          [
            attribute.class("admin-form"),
            event.on_submit(fn(_) { UserSubmittedCreateToken }),
          ],
          [
            admin_text_input(
              text(model.language, "username"),
              model.admin_username,
              "text",
              "off",
              True,
              UserChangedAdminUsername,
            ),
            admin_text_input(
              text(model.language, "label"),
              model.token_label,
              "text",
              "off",
              False,
              UserChangedTokenLabel,
            ),
            html.button([attribute.type_("submit")], [
              html.text(text(model.language, "create_token")),
            ]),
          ],
        ),
        html.form(
          [
            attribute.class("admin-form compact"),
            event.on_submit(fn(_) { UserSubmittedRevokeToken }),
          ],
          [
            admin_text_input(
              text(model.language, "token_id"),
              model.token_id,
              "text",
              "off",
              True,
              UserChangedTokenId,
            ),
            html.button([attribute.class("danger"), attribute.type_("submit")], [
              html.text(text(model.language, "revoke_token")),
            ]),
          ],
        ),
      ]),
      html.section([], [
        html.h3([], [html.text(text(model.language, "access"))]),
        html.ul([], list.map(model.access_rules, text_item)),
        html.form(
          [
            attribute.class("admin-form"),
            event.on_submit(fn(_) { UserSubmittedPutAcl }),
          ],
          [
            admin_text_input(
              text(model.language, "username"),
              model.admin_username,
              "text",
              "off",
              True,
              UserChangedAdminUsername,
            ),
            admin_text_input(
              text(model.language, "topic_pattern"),
              model.acl_pattern,
              "text",
              "off",
              True,
              UserChangedAclPattern,
            ),
            html.label([], [
              html.span([], [html.text(text(model.language, "permission"))]),
              html.select(
                [
                  attribute.value(model.acl_permission),
                  event.on_change(UserChangedAclPermission),
                ],
                [
                  html.option([attribute.value("deny")], "Deny"),
                  html.option([attribute.value("read")], "Read"),
                  html.option([attribute.value("write")], "Write"),
                  html.option([attribute.value("read-write")], "Read/write"),
                ],
              ),
            ]),
            html.div([attribute.class("row")], [
              html.button([attribute.type_("submit")], [
                html.text(text(model.language, "save_rule")),
              ]),
              html.button(
                [
                  attribute.class("danger"),
                  attribute.type_("button"),
                  event.on_click(UserSubmittedDeleteAcl),
                ],
                [html.text(text(model.language, "delete_rule"))],
              ),
            ]),
          ],
        ),
      ]),
      html.section([], [
        html.h3([], [html.text(text(model.language, "delivery_jobs"))]),
        html.ul([], list.map(model.delivery_jobs, text_item)),
      ]),
      html.section([], [
        html.h3([], [html.text(text(model.language, "attachments"))]),
        html.ul([], list.map(model.attachments, text_item)),
        html.form(
          [
            attribute.class("admin-form compact"),
            event.on_submit(fn(_) { UserSubmittedDeleteAttachment }),
          ],
          [
            admin_text_input(
              text(model.language, "attachment_key"),
              model.attachment_key,
              "text",
              "off",
              True,
              UserChangedAttachmentKey,
            ),
            html.button([attribute.class("danger"), attribute.type_("submit")], [
              html.text(text(model.language, "delete_attachment")),
            ]),
          ],
        ),
      ]),
    ],
  )
}

fn view(model: Model) -> Element(Message) {
  html.div(
    [
      attribute.lang(case model.language {
        English -> "en"
        Japanese -> "ja"
      }),
    ],
    [
      html.header([attribute.class("topbar")], [
        html.a([attribute.class("wordmark"), attribute.href("/")], [
          html.span([attribute.class("mark")], [html.text("N")]),
          html.text(" Notify"),
        ]),
        html.nav([attribute.aria_label("Application controls")], [
          html.button(
            [
              attribute.class("quiet"),
              attribute.type_("button"),
              event.on_click(UserChangedLanguage),
            ],
            [
              html.text(case model.language {
                English -> "日本語"
                Japanese -> "English"
              }),
            ],
          ),
          html.button(
            [
              attribute.class("quiet"),
              attribute.type_("button"),
              attribute.aria_label("Change colour theme"),
              event.on_click(UserToggledTheme),
            ],
            [html.text("◐")],
          ),
          html.button(
            [
              attribute.class("quiet"),
              attribute.type_("button"),
              event.on_click(UserOpenedLogin),
            ],
            [
              html.text(case model.username {
                "" -> text(model.language, "sign_in")
                username -> username
              }),
            ],
          ),
        ]),
      ]),
      html.main([attribute.class("layout")], [
        html.aside([attribute.class("sidebar")], [
          html.p([attribute.class("eyebrow")], [
            html.text(text(model.language, "topics")),
          ]),
          html.form(
            [
              attribute.class("row"),
              event.on_submit(fn(_) { UserSubmittedTopic }),
            ],
            [
              html.label([attribute.class("sr-only"), attribute.for("topic")], [
                html.text(text(model.language, "topic")),
              ]),
              html.input([
                attribute.id("topic"),
                attribute.name("topic"),
                attribute.autocomplete("off"),
                attribute.pattern("[-_A-Za-z0-9]{1,64}"),
                attribute.placeholder("alerts"),
                attribute.required(True),
                attribute.value(model.topic_input),
                event.on_input(UserChangedTopicInput),
              ]),
              html.button([attribute.type_("submit")], [
                html.text(text(model.language, "open")),
              ]),
            ],
          ),
          html.div(
            [
              attribute.classes([
                #("status", True),
                #("muted", model.connection != Live),
                #("ok", model.connection == Live),
              ]),
              attribute.role("status"),
            ],
            [html.text(connection_text(model))],
          ),
          html.button(
            [
              attribute.classes([
                #("quiet", True),
                #("full", True),
                #("push-control", True),
              ]),
              attribute.type_("button"),
              attribute.hidden(!model.push_available),
              attribute.disabled(model.topic == ""),
              event.on_click(UserToggledPush),
            ],
            [
              html.text(
                text(model.language, case model.push_enabled {
                  True -> "disable_notifications"
                  False -> "enable_notifications"
                }),
              ),
            ],
          ),
          html.output(
            [attribute.class("status muted"), attribute.role("status")],
            [html.text(model.push_status)],
          ),
          html.hr([]),
          html.button(
            [
              attribute.class("quiet full"),
              attribute.type_("button"),
              event.on_click(UserOpenedAdmin),
            ],
            [html.text(text(model.language, "system"))],
          ),
        ]),
        html.section(
          [
            attribute.class("workspace"),
            attribute.aria_labelledby("timeline-title"),
          ],
          [
            html.div([attribute.class("section-title")], [
              html.div([], [
                html.p([attribute.class("eyebrow")], [
                  html.text(case model.topic {
                    "" -> "—"
                    topic -> topic
                  }),
                ]),
                html.h1([attribute.id("timeline-title")], [
                  html.text(text(model.language, "timeline")),
                ]),
              ]),
              html.label([attribute.class("filter")], [
                html.span([attribute.class("sr-only")], [
                  html.text(text(model.language, "filter")),
                ]),
                html.input([
                  attribute.type_("search"),
                  attribute.placeholder(text(model.language, "filter")),
                  attribute.value(model.filter),
                  event.on_input(UserChangedFilter),
                ]),
              ]),
            ]),
            html.ol(
              [attribute.class("timeline"), attribute.aria_live("polite")],
              list.map(visible_notifications(model), notification_view),
            ),
            html.form(
              [
                attribute.class("composer"),
                event.on_submit(fn(_) { UserSubmittedPublish }),
              ],
              [
                html.label([], [
                  html.span([], [html.text(text(model.language, "message"))]),
                  html.textarea(
                    [
                      attribute.name("message"),
                      attribute.rows(3),
                      attribute.required(True),
                      event.on_input(UserChangedMessage),
                    ],
                    model.message,
                  ),
                ]),
                html.div([attribute.class("composer-grid")], [
                  html.label([], [
                    html.span([], [html.text(text(model.language, "title"))]),
                    html.input([
                      attribute.name("title"),
                      attribute.value(model.title),
                      event.on_input(UserChangedTitle),
                    ]),
                  ]),
                  html.label([], [
                    html.span([], [html.text(text(model.language, "priority"))]),
                    html.select(
                      [
                        attribute.name("priority"),
                        event.on_change(UserChangedPriority),
                      ],
                      [
                        html.option([attribute.value("default")], "Default"),
                        html.option([attribute.value("min")], "Min"),
                        html.option([attribute.value("low")], "Low"),
                        html.option([attribute.value("high")], "High"),
                        html.option([attribute.value("max")], "Max"),
                      ],
                    ),
                  ]),
                  html.label([], [
                    html.span([], [html.text(text(model.language, "tags"))]),
                    html.input([
                      attribute.name("tags"),
                      attribute.placeholder("warning,deploy"),
                      attribute.value(model.tags),
                      event.on_input(UserChangedTags),
                    ]),
                  ]),
                  html.label([], [
                    html.span([], [
                      html.text(text(model.language, "attachment")),
                    ]),
                    html.input([
                      attribute.id("attachment"),
                      attribute.name("attachment"),
                      attribute.type_("file"),
                    ]),
                  ]),
                ]),
                html.div([attribute.class("row end")], [
                  html.button([attribute.type_("submit")], [
                    html.text(text(model.language, "publish")),
                  ]),
                ]),
                html.output([attribute.role("status")], [
                  html.text(model.publish_status),
                ]),
              ],
            ),
          ],
        ),
        admin_panel(model),
      ]),
      login_dialog(model),
    ],
  )
}

pub fn main() {
  let app = lustre.application(init, application_update, view)
  let assert Ok(_) = lustre.start(app, "#app", Nil)
}
