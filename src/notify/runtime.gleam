import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import notify/access.{type Access}
import notify/attachment_store.{type Store as AttachmentStore}
import notify/audit.{type Store as AuditStore}
import notify/cluster/health.{type Store as ClusterHealthStore}
import notify/core/message.{type Message}
import notify/delivery.{type Store as DeliveryStore}
import notify/rate_limit.{type Limiter}
import notify/storage.{type Storage}
import notify/webpush.{type Store as WebPushStore}

pub type Clock {
  Clock(now: fn() -> Int)
}

pub type IdGenerator {
  IdGenerator(next: fn() -> String)
}

pub type WebPushRuntime {
  WebPushRuntime(
    store: WebPushStore,
    public_key: String,
    private_key: String,
    subscriber: String,
  )
}

pub type RelayRuntime {
  RelayRuntime(base_url: String, token: String)
}

pub type CommitError {
  CommitPersistence(storage.Error)
  CommitDelivery(delivery.Error)
}

pub type Committer {
  Committer(
    commit: fn(Message, List(delivery.NewJob)) -> Result(Message, CommitError),
  )
}

pub type Runtime {
  Runtime(
    storage: Storage,
    clock: Clock,
    ids: IdGenerator,
    retention_seconds: Int,
    broadcast: fn(Message) -> Nil,
    access: Access,
    attachments: Option(AttachmentStore),
    attachment_base_url: String,
    attachment_file_size_bytes: Int,
    attachment_total_size_bytes: Int,
    attachment_retention_seconds: Int,
    deliveries: Option(DeliveryStore),
    webpush: Option(WebPushRuntime),
    relay: Option(RelayRuntime),
    rate_limiter: Option(Limiter),
    audit: Option(AuditStore),
    cluster_health: Option(ClusterHealthStore),
    template_directory: String,
    committer: Committer,
  )
}

pub fn new(
  storage storage: Storage,
  clock clock: Clock,
  ids ids: IdGenerator,
  retention_seconds retention_seconds: Int,
) -> Runtime {
  Runtime(
    storage:,
    clock:,
    ids:,
    retention_seconds:,
    broadcast: fn(_) { Nil },
    access: access.open(),
    attachments: None,
    attachment_base_url: "",
    attachment_file_size_bytes: 15_728_640,
    attachment_total_size_bytes: 104_857_600,
    attachment_retention_seconds: 10_800,
    deliveries: None,
    webpush: None,
    relay: None,
    rate_limiter: None,
    audit: None,
    cluster_health: None,
    template_directory: "",
    committer: Committer(fn(message, _) {
      storage.save(message) |> result.map_error(CommitPersistence)
    }),
  )
}

pub fn with_access(runtime: Runtime, access control: Access) -> Runtime {
  Runtime(..runtime, access: control)
}

pub fn with_attachments(
  runtime: Runtime,
  store: AttachmentStore,
  base_url base_url: String,
  retention_seconds retention_seconds: Int,
) -> Runtime {
  Runtime(
    ..runtime,
    attachments: Some(store),
    attachment_base_url: base_url,
    attachment_retention_seconds: retention_seconds,
  )
}

pub fn with_attachment_limits(
  runtime: Runtime,
  file_size_bytes file_size_bytes: Int,
  total_size_bytes total_size_bytes: Int,
) -> Runtime {
  Runtime(
    ..runtime,
    attachment_file_size_bytes: file_size_bytes,
    attachment_total_size_bytes: total_size_bytes,
  )
}

pub fn with_broadcast(
  runtime: Runtime,
  broadcast: fn(Message) -> Nil,
) -> Runtime {
  Runtime(..runtime, broadcast:)
}

pub fn with_deliveries(runtime: Runtime, store: DeliveryStore) -> Runtime {
  Runtime(
    ..runtime,
    deliveries: Some(store),
    committer: Committer(fn(message, jobs) {
      use saved <- result.try(
        runtime.storage.save(message) |> result.map_error(CommitPersistence),
      )
      use _ <- result.try(
        list.try_each(jobs, fn(job) {
          store.enqueue(job)
          |> result.map(fn(_) { Nil })
          |> result.map_error(CommitDelivery)
        }),
      )
      Ok(saved)
    }),
  )
}

pub fn with_atomic_commit(
  runtime: Runtime,
  atomic: storage.AtomicCommit,
) -> Runtime {
  let storage.AtomicCommit(commit) = atomic
  Runtime(
    ..runtime,
    committer: Committer(fn(message, jobs) {
      commit(message, jobs) |> result.map_error(CommitPersistence)
    }),
  )
}

pub fn with_webpush(runtime: Runtime, configured: WebPushRuntime) -> Runtime {
  Runtime(..runtime, webpush: Some(configured))
}

pub fn with_relay(runtime: Runtime, configured: RelayRuntime) -> Runtime {
  Runtime(..runtime, relay: Some(configured))
}

pub fn with_rate_limiter(runtime: Runtime, limiter: Limiter) -> Runtime {
  Runtime(..runtime, rate_limiter: Some(limiter))
}

pub fn with_audit(runtime: Runtime, store: AuditStore) -> Runtime {
  Runtime(..runtime, audit: Some(store))
}

pub fn with_cluster_health(
  runtime: Runtime,
  store: ClusterHealthStore,
) -> Runtime {
  Runtime(..runtime, cluster_health: Some(store))
}

pub fn with_template_directory(runtime: Runtime, directory: String) -> Runtime {
  Runtime(..runtime, template_directory: directory)
}

pub fn with_public_base_url(runtime: Runtime, base_url: String) -> Runtime {
  Runtime(..runtime, attachment_base_url: base_url)
}

pub fn system_clock() -> Clock {
  Clock(unix_seconds)
}

pub fn secure_ids() -> IdGenerator {
  IdGenerator(random_id)
}

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int

@external(erlang, "notify_ffi", "random_id")
fn random_id() -> String
