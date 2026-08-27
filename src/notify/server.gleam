import gleam/bytes_tree
import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import mist
import notify/access
import notify/attachment_store
import notify/attachment_store/filesystem as attachment_filesystem
import notify/attachment_store/postgres as attachment_postgres
import notify/attachment_store/s3 as attachment_s3
import notify/audit
import notify/audit/postgres as audit_postgres
import notify/audit/sqlite as audit_sqlite
import notify/broker
import notify/cluster/postgres_bus
import notify/config.{type Config}
import notify/delivery
import notify/delivery/postgres as delivery_postgres
import notify/delivery/relay as delivery_relay
import notify/delivery/sqlite as delivery_sqlite
import notify/delivery/worker as delivery_worker
import notify/http/attachment_upload
import notify/http/h3
import notify/http/live
import notify/http/rate_policy
import notify/http/router
import notify/http/transport
import notify/http3_listener
import notify/identity
import notify/identity/postgres as identity_postgres
import notify/identity/sqlite as identity_sqlite
import notify/log as notify_log
import notify/network
import notify/proxy
import notify/rate_limit
import notify/runtime
import notify/scheduler
import notify/security/token as security_token
import notify/sqlite_lock
import notify/storage
import notify/storage/postgres as storage_postgres
import notify/storage/sqlite
import notify/webpush
import notify/webpush/postgres as webpush_postgres
import notify/webpush/provider as webpush_provider
import notify/webpush/sqlite as webpush_sqlite
import postgleam/config as postgres_configuration

pub type Error {
  StorageError(storage.Error)
  BrokerStartError(actor.StartError)
  HttpStartError(actor.StartError)
  Http3StartError(http3_listener.StartError)
  DatabaseDirectoryError(String)
  IdentityStartError(identity.Error)
  AccessStartError(access.Error)
  AttachmentStartError(attachment_store.Error)
  DeliveryStartError(delivery.Error)
  WebPushStartError(webpush.Error)
  RateLimitStartError(rate_limit.Error)
  AuditStartError(audit.Error)
  SQLiteLockError(sqlite_lock.Error)
}

pub opaque type Started {
  Started(
    supervisor: Pid,
    http3: http3_listener.Started,
    owned_processes: List(Pid),
    sqlite_lock: Option(sqlite_lock.Lock),
  )
}

type StartedServers {
  StartedServers(supervisor: Pid, http3: http3_listener.Started)
}

type Persistence {
  Persistence(
    storage: storage.Storage,
    commit: storage.AtomicCommit,
    postgres_adapter: Option(storage_postgres.Adapter),
  )
}

pub fn start(config: Config) -> Result(Started, Error) {
  network.configure_tcp_clients()
  let previously_trapping_exits = set_trap_exits(True)
  let existing_processes = linked_processes()
  let outcome = case start_sqlite_process_lock(config) {
    Error(error) -> Error(error)
    Ok(sqlite_process_lock) ->
      case start_after_lock(config) {
        Ok(started) ->
          Ok(Started(
            supervisor: started.supervisor,
            http3: started.http3,
            owned_processes: newly_linked_processes(existing_processes),
            sqlite_lock: sqlite_process_lock,
          ))
        Error(error) -> {
          let _ =
            shutdown_processes(newly_linked_processes(existing_processes), 5000)
          release_sqlite_process_lock(sqlite_process_lock)
          Error(error)
        }
      }
  }
  case outcome, previously_trapping_exits {
    Error(_), False -> flush_exit_messages()
    _, _ -> Nil
  }
  let _ = set_trap_exits(previously_trapping_exits)
  outcome
}

fn start_after_lock(config: Config) -> Result(StartedServers, Error) {
  use persistence <- result.try(start_storage(config))
  let Persistence(persistent_storage, atomic_commit, postgres_adapter) =
    persistence
  use bus <- result.try(broker.start() |> result.map_error(BrokerStartError))
  use attachment_files <- result.try(
    open_attachment_store(config) |> result.map_error(AttachmentStartError),
  )
  use delivery_store <- result.try(start_deliveries(config))
  use webpush_runtime <- result.try(start_webpush(config))
  use access_started <- result.try(start_access(config))
  use limiter <- result.try(start_rate_limiter(config))
  use audit_store <- result.try(start_audit(config))
  let #(access_control, setup_token) = access_started
  let runtime =
    runtime.new(
      storage: persistent_storage,
      clock: runtime.system_clock(),
      ids: runtime.secure_ids(),
      retention_seconds: config.retention_seconds,
    )
    |> runtime.with_access(access_control)
    |> runtime.with_attachments(
      attachment_files,
      base_url: public_base_url(config),
      retention_seconds: config.attachment_retention_seconds,
    )
    |> runtime.with_attachment_limits(
      file_size_bytes: config.attachment_file_size_bytes,
      total_size_bytes: config.attachment_total_size_bytes,
    )
    |> runtime.with_deliveries(delivery_store)
    |> runtime.with_atomic_commit(atomic_commit)
    |> runtime.with_rate_limiter(limiter)
    |> runtime.with_audit(audit_store)
    |> runtime.with_template_directory(config.template_directory)
  let runtime = case config.cluster_enabled {
    True -> runtime
    False -> runtime.with_broadcast(runtime, bus.broadcast)
  }
  let runtime = case config.cluster_enabled, postgres_adapter {
    True, Some(adapter) ->
      runtime.with_cluster_health(runtime, adapter.cluster_health)
    _, _ -> runtime
  }
  let runtime = case webpush_runtime {
    None -> runtime
    Some(configured) -> runtime.with_webpush(runtime, configured)
  }
  let runtime = case string.is_empty(config.relay_url) {
    True -> runtime
    False ->
      runtime.with_relay(
        runtime,
        runtime.RelayRuntime(
          base_url: config.relay_url,
          token: config.relay_token,
        ),
      )
  }
  use http3_started <- result.try(
    http3_listener.start(config, fn(http3_runtime, request) {
      h3.handle(
        request,
        runtime.with_http3(runtime, http3_runtime),
        bus,
        config,
      )
    })
    |> result.map_error(Http3StartError),
  )
  let runtime =
    runtime.with_http3(runtime, http3_listener.runtime(http3_started))
  let body_too_large =
    response.new(413)
    |> response.set_header("content-type", "application/json; charset=utf-8")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(
        "{\"code\":41301,\"http\":413,\"error\":\"request body too large\"}",
      )),
    )

  let http_server =
    mist.new(fn(request) {
      let started_at = monotonic_milliseconds()
      let http_protocol = mist_http_protocol(request.body)
      let request_id = router.correlation_id(request)
      let client_ip = effective_client_ip(request, config.trusted_proxies)
      let request =
        request
        |> request.set_header("x-request-id", request_id)
        |> request.set_header("x-notify-client-ip", client_ip)
      let reply =
        enforce_rate_limit(
          request,
          runtime,
          client_ip,
          config.max_request_bytes,
          fn() {
            case live.route(request, runtime, bus, 128) {
              Some(response) -> response
              None ->
                case
                  router.streamed_attachment(
                    request,
                    runtime,
                    fn(store, expires) {
                      stream_attachment(
                        request,
                        store,
                        expires,
                        config.max_request_bytes,
                      )
                    },
                  )
                {
                  Some(reply) ->
                    reply
                    // A rejected streaming upload may leave unread bytes on
                    // this connection. Closing it prevents those bytes from
                    // being parsed as the next keep-alive request.
                    |> response.set_header("connection", "close")
                    |> to_mist_response
                  None ->
                    case filesystem_download(request, runtime, config) {
                      Some(reply) -> reply
                      None ->
                        case mist.read_body(request, config.max_request_bytes) {
                          Ok(request) ->
                            request
                            |> router.handle(runtime)
                            |> to_mist_response
                          Error(_) -> body_too_large
                        }
                    }
                }
            }
          },
        )
      let runtime.Clock(now) = runtime.clock
      notify_log.request(
        log_format(config.log_format),
        at: now(),
        request_id:,
        client_ip:,
        method: http.method_to_string(request.method),
        target: "/" <> string.join(request.path_segments(request), "/"),
        http_protocol:,
        status: reply.status,
        duration_ms: int.max(0, monotonic_milliseconds() - started_at),
      )
      reply
      |> response.set_header("x-request-id", request_id)
      |> response.set_header(
        "alt-svc",
        http3_listener.alt_svc(http3_listener.runtime(http3_started)),
      )
    })
    |> mist.bind(config.bind)
    |> mist.port(config.port)
  let http_server = case string.is_empty(config.tls_certificate) {
    True -> http_server
    False ->
      mist.with_tls(
        http_server,
        certfile: config.tls_certificate,
        keyfile: config.tls_key,
      )
  }
  let supervision =
    static_supervisor.new(strategy: static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 10, period: 60)
    |> static_supervisor.add(mist.supervised(http_server))
    |> static_supervisor.add(scheduler.supervised(runtime, 1000))
  let supervision = case config.cluster_enabled, postgres_adapter {
    True, Some(adapter) ->
      static_supervisor.add(
        supervision,
        postgres_bus.supervised(
          postgres_config(config),
          adapter,
          config.node_id,
          fn(message) {
            bus.dispatch(message)
            Ok(Nil)
          },
        ),
      )
    _, _ -> supervision
  }
  let supervision = case runtime.webpush, runtime.deliveries {
    Some(configured), Some(outbox) -> {
      let runtime.Clock(now) = runtime.clock
      static_supervisor.add(
        supervision,
        delivery_worker.supervised(
          outbox,
          webpush_provider.new(
            configured,
            webpush_provider.production_sender(),
            now,
          ),
          config.node_id <> "-webpush",
          now,
          1000,
        ),
      )
    }
    _, _ -> supervision
  }
  let supervision = case runtime.relay, runtime.deliveries {
    Some(configured), Some(outbox) -> {
      let runtime.Clock(now) = runtime.clock
      static_supervisor.add(
        supervision,
        delivery_worker.supervised(
          outbox,
          delivery_relay.provider(
            configured.token,
            delivery_relay.production_sender(),
          ),
          config.node_id <> "-relay",
          now,
          1000,
        ),
      )
    }
    _, _ -> supervision
  }
  case static_supervisor.start(supervision) {
    Error(error) -> {
      http3_listener.stop(http3_started)
      Error(HttpStartError(error))
    }
    Ok(supervisor) -> {
      case setup_token {
        None -> Nil
        Some(token) ->
          io.println(
            "One-time setup URL (expires in 15 minutes): "
            <> public_base_url(config)
            <> "/setup?token="
            <> token,
          )
      }
      Ok(StartedServers(supervisor.pid, http3_started))
    }
  }
}

/// Stop accepting new connections, wait for the supervised workers to stop,
/// and finally release the single-node SQLite ownership lock.
///
/// Returns `False` when the supervisor exceeded the deadline and had to be
/// killed. The lock is still released after the forced stop completes.
pub fn stop(started: Started, timeout_milliseconds: Int) -> Bool {
  let Started(supervisor, http3, owned_processes, sqlite_process_lock) = started
  http3_listener.stop(http3)
  let listener_stopped = shutdown_process(supervisor, timeout_milliseconds)
  let remaining_processes =
    list.filter(owned_processes, fn(pid) { pid != supervisor })
  let resources_stopped =
    shutdown_processes(remaining_processes, timeout_milliseconds)
  release_sqlite_process_lock(sqlite_process_lock)
  listener_stopped && resources_stopped
}

fn newly_linked_processes(existing: List(Pid)) -> List(Pid) {
  linked_processes()
  |> list.filter(fn(pid) { !list.contains(existing, pid) })
}

fn release_sqlite_process_lock(lock: Option(sqlite_lock.Lock)) -> Nil {
  case lock {
    None -> Nil
    Some(lock) -> sqlite_lock.release(lock)
  }
}

fn start_sqlite_process_lock(
  config: Config,
) -> Result(Option(sqlite_lock.Lock), Error) {
  case config.database_backend {
    config.PostgreSQL -> Ok(None)
    config.SQLite ->
      sqlite_lock.acquire(config.database_path)
      |> result.map(Some)
      |> result.map_error(SQLiteLockError)
  }
}

fn enforce_rate_limit(
  request: request.Request(mist.Connection),
  runtime: runtime.Runtime,
  client_key: String,
  maximum_request_bytes: Int,
  continue: fn() -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case runtime.rate_limiter {
    None -> continue()
    Some(limiter) -> {
      let runtime.Clock(now) = runtime.clock
      let checked_at = now()
      enforce_rate_charges(
        rate_policy.preflight(request, maximum_request_bytes),
        limiter,
        client_key,
        checked_at,
        fn() {
          let reply = continue()
          enforce_rate_charges(
            rate_policy.after_response(
              request,
              reply.status,
              response_content_length(reply),
            ),
            limiter,
            client_key,
            checked_at,
            fn() { reply },
          )
        },
      )
    }
  }
}

fn enforce_rate_charges(
  charges: List(rate_policy.Charge),
  limiter: rate_limit.Limiter,
  client_key: String,
  checked_at: Int,
  continue: fn() -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case charges {
    [] -> continue()
    [rate_policy.Charge(first_bucket, _), ..] ->
      case
        limiter.check_many(
          charges
            |> list.map(fn(charge) {
              let rate_policy.Charge(bucket, cost) = charge
              #(bucket, cost)
            }),
          client_key,
          checked_at,
        )
      {
        Ok(decisions) ->
          apply_rate_decisions(decisions, limiter, checked_at, continue)
        Error(_) ->
          response.new(503)
          |> response.set_header(
            "content-type",
            "application/json; charset=utf-8",
          )
          |> response.set_header("retry-after", "1")
          |> response.set_header(
            "x-notify-ratelimit-bucket",
            rate_limit.bucket_name(first_bucket),
          )
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(
              "{\"code\":50301,\"http\":503,\"error\":\"temporarily unavailable: rate limiter\"}",
            )),
          )
      }
  }
}

fn apply_rate_decisions(
  decisions: List(#(rate_limit.Bucket, rate_limit.Decision)),
  limiter: rate_limit.Limiter,
  checked_at: Int,
  continue: fn() -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case decisions {
    [] -> continue()
    [#(bucket, decision), ..remaining_decisions] ->
      case decision {
        rate_limit.Allowed(remaining, reset_at) ->
          apply_rate_decisions(
            remaining_decisions,
            limiter,
            checked_at,
            continue,
          )
          |> rate_limit_headers_if_missing(
            limiter.limit(bucket),
            remaining,
            int.max(0, reset_at - checked_at),
            bucket,
          )
        rate_limit.Limited(retry_after, reset_at) ->
          response.new(429)
          |> response.set_header(
            "content-type",
            "application/json; charset=utf-8",
          )
          |> response.set_header("retry-after", int.to_string(retry_after))
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(
              "{\"code\":42901,\"http\":429,\"error\":\"limit reached: too many requests\"}",
            )),
          )
          |> rate_limit_headers(
            limiter.limit(bucket),
            0,
            int.max(1, reset_at - checked_at),
            bucket,
          )
      }
  }
}

fn rate_limit_headers_if_missing(
  reply: Response(mist.ResponseData),
  limit: Int,
  remaining: Int,
  reset_after: Int,
  bucket: rate_limit.Bucket,
) -> Response(mist.ResponseData) {
  case response.get_header(reply, "x-notify-ratelimit-bucket") {
    Ok(_) -> reply
    Error(_) -> rate_limit_headers(reply, limit, remaining, reset_after, bucket)
  }
}

fn response_content_length(reply: Response(mist.ResponseData)) -> Option(Int) {
  case response.get_header(reply, "content-length") {
    Error(_) -> None
    Ok(value) -> value |> int.parse |> option.from_result
  }
}

fn rate_limit_headers(
  reply: Response(mist.ResponseData),
  limit: Int,
  remaining: Int,
  reset_after: Int,
  bucket: rate_limit.Bucket,
) -> Response(mist.ResponseData) {
  reply
  |> response.set_header("ratelimit-limit", int.to_string(limit))
  |> response.set_header("ratelimit-remaining", int.to_string(remaining))
  |> response.set_header("ratelimit-reset", int.to_string(reset_after))
  |> response.set_header(
    "x-notify-ratelimit-bucket",
    rate_limit.bucket_name(bucket),
  )
}

fn public_base_url(config: Config) -> String {
  case config.base_url {
    Some(url) -> url
    None ->
      case string.is_empty(config.tls_certificate) {
        True -> "http://" <> config.bind <> ":" <> int.to_string(config.port)
        False -> "https://" <> config.bind <> ":" <> int.to_string(config.port)
      }
  }
}

fn log_format(format: config.LogFormat) -> notify_log.Format {
  case format {
    config.HumanLogs -> notify_log.Human
    config.JsonLogs -> notify_log.Json
  }
}

fn effective_client_ip(
  request: request.Request(mist.Connection),
  trusted_proxies: List(String),
) -> String {
  case mist.get_connection_info(request.body) {
    Error(_) -> "unknown"
    Ok(info) ->
      proxy.client_ip(
        mist.ip_address_to_string(info.ip_address),
        trusted_proxies,
        request.get_header(request, "x-forwarded-for")
          |> option.from_result,
        request.get_header(request, "forwarded") |> option.from_result,
      )
  }
}

fn start_rate_limiter(config: Config) -> Result(rate_limit.Limiter, Error) {
  let policies =
    rate_limit.Policies(
      requests: config.rate_limit_requests,
      subscriptions: config.rate_limit_subscriptions,
      topic_creations: config.rate_limit_topic_creations,
      auth_failures: config.rate_limit_auth_failures,
      attachment_mebibytes: config.rate_limit_attachment_mebibytes,
      attachment_uploads: config.rate_limit_attachment_uploads,
    )
  case config.cluster_enabled {
    True ->
      rate_limit.postgres_with_policies(
        postgres_config(config),
        policies,
        window_seconds: config.rate_limit_window_seconds,
      )
    False ->
      rate_limit.memory_with_policies(
        policies,
        window_seconds: config.rate_limit_window_seconds,
      )
  }
  |> result.map_error(RateLimitStartError)
}

fn start_audit(config: Config) -> Result(audit.Store, Error) {
  case config.database_backend {
    config.SQLite -> audit_sqlite.start(config.database_path)
    config.PostgreSQL -> audit_postgres.start(postgres_config(config))
  }
  |> result.map_error(AuditStartError)
}

fn start_access(
  config: Config,
) -> Result(#(access.Access, Option(String)), Error) {
  case config.dev_open {
    True -> Ok(#(access.open(), None))
    False -> {
      let runtime.Clock(now) = runtime.system_clock()
      use start_result <- result.try(start_identity(config, now))
      let #(store, setup_token) = start_result
      use control <- result.try(
        access.managed(store) |> result.map_error(AccessStartError),
      )
      Ok(#(control, setup_token))
    }
  }
}

fn start_storage(config: Config) -> Result(Persistence, Error) {
  case config.database_backend {
    config.SQLite -> {
      use _ <- result.try(prepare_database(config.database_path))
      use adapter <- result.try(
        sqlite.start_adapter(config.database_path)
        |> result.map_error(StorageError),
      )
      Ok(Persistence(adapter.storage, adapter.commit, None))
    }
    config.PostgreSQL -> {
      use adapter <- result.try(
        storage_postgres.start(postgres_config(config), config.node_id)
        |> result.map_error(StorageError),
      )
      let storage_postgres.Adapter(storage: persistent, commit:, ..) = adapter
      Ok(Persistence(persistent, commit, Some(adapter)))
    }
  }
}

fn start_identity(
  config: Config,
  now: fn() -> Int,
) -> Result(#(identity.Store, Option(String)), Error) {
  case config.database_backend {
    config.SQLite ->
      identity_sqlite.start(
        config.database_path,
        now,
        security_token.secure_entropy,
      )
      |> result.map(fn(started) {
        let identity_sqlite.Started(store, setup_token) = started
        #(store, setup_token)
      })
      |> result.map_error(IdentityStartError)
    config.PostgreSQL ->
      identity_postgres.start(
        postgres_config(config),
        now,
        security_token.secure_entropy,
      )
      |> result.map(fn(started) {
        let identity_postgres.Started(store, setup_token) = started
        #(store, setup_token)
      })
      |> result.map_error(IdentityStartError)
  }
}

pub fn open_attachment_store(
  config: Config,
) -> Result(attachment_store.Store, attachment_store.Error) {
  case config.attachment_backend {
    config.Filesystem | config.SharedFilesystem ->
      attachment_filesystem.start(
        config.attachment_directory,
        max_file_bytes: config.attachment_file_size_bytes,
        max_total_bytes: config.attachment_total_size_bytes,
      )

    config.PostgreSQLBlob ->
      attachment_postgres.start(
        postgres_config(config),
        max_file_bytes: config.attachment_file_size_bytes,
        max_total_bytes: config.attachment_total_size_bytes,
      )

    config.S3Compatible ->
      attachment_s3.start(
        attachment_s3.Config(
          endpoint: config.s3_endpoint,
          bucket: config.s3_bucket,
          region: config.s3_region,
          access_key: config.s3_access_key,
          secret_key: config.s3_secret_key,
          path_style: config.s3_path_style,
        ),
        max_file_bytes: config.attachment_file_size_bytes,
        max_total_bytes: config.attachment_total_size_bytes,
      )
  }
}

fn start_deliveries(config: Config) -> Result(delivery.Store, Error) {
  case config.database_backend {
    config.SQLite ->
      delivery_sqlite.start(config.database_path)
      |> result.map_error(DeliveryStartError)
    config.PostgreSQL ->
      delivery_postgres.start(postgres_config(config))
      |> result.map_error(DeliveryStartError)
  }
}

fn start_webpush(
  config: Config,
) -> Result(Option(runtime.WebPushRuntime), Error) {
  case string.is_empty(config.webpush_public_key) {
    True -> Ok(None)
    False -> {
      use store <- result.try(
        case config.database_backend {
          config.SQLite ->
            webpush_sqlite.start(config.database_path, max_endpoints_per_ip: 10)
          config.PostgreSQL ->
            webpush_postgres.start(
              postgres_config(config),
              max_endpoints_per_ip: 10,
            )
        }
        |> result.map_error(WebPushStartError),
      )
      Ok(
        Some(runtime.WebPushRuntime(
          store:,
          public_key: config.webpush_public_key,
          private_key: config.webpush_private_key,
          subscriber: config.webpush_subscriber,
        )),
      )
    }
  }
}

pub fn postgres_config(config: Config) -> postgres_configuration.Config {
  let ssl = case config.postgres_ssl {
    config.SslDisabled -> postgres_configuration.SslDisabled
    config.SslVerified -> postgres_configuration.SslVerified
    config.SslUnverified -> postgres_configuration.SslUnverified
  }
  postgres_configuration.default()
  |> postgres_configuration.host(config.postgres_host)
  |> postgres_configuration.port(config.postgres_port)
  |> postgres_configuration.database(config.postgres_database)
  |> postgres_configuration.username(config.postgres_username)
  |> postgres_configuration.password(config.postgres_password)
  |> postgres_configuration.ssl(ssl)
}

fn to_mist_response(reply: Response(BitArray)) -> Response(mist.ResponseData) {
  response.map(reply, fn(body) {
    body
    |> bytes_tree.from_bit_array
    |> mist.Bytes
  })
}

fn stream_attachment(
  request: request.Request(mist.Connection),
  store: attachment_store.Store,
  expires: Int,
  maximum_request_bytes: Int,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  case mist.stream(request) {
    Error(_) ->
      Error(attachment_store.Unavailable("request body stream is malformed"))
    Ok(consume) ->
      attachment_upload.consume(
        transport.body_reader(
          consume,
          fn(consume, maximum_bytes) {
            case consume(maximum_bytes) {
              Error(_) -> Error(transport.BodyUnavailable)
              Ok(mist.Done) -> Ok(#(transport.BodyEnd, consume))
              Ok(mist.Chunk(chunk, next)) ->
                Ok(#(transport.BodyChunk(chunk), next))
            }
          },
          fn(_) { Nil },
        ),
        store,
        expires,
        maximum_request_bytes,
      )
  }
}

fn filesystem_download(
  incoming: request.Request(mist.Connection),
  runtime: runtime.Runtime,
  config: Config,
) -> Option(Response(mist.ResponseData)) {
  case
    config.attachment_backend,
    incoming.method,
    request.path_segments(incoming)
  {
    config.Filesystem, http.Get, ["file", _, key]
    | config.Filesystem, http.Get, ["file", _, key, _]
    | config.SharedFilesystem, http.Get, ["file", _, key]
    | config.SharedFilesystem, http.Get, ["file", _, key, _]
    -> {
      let head_request =
        incoming
        |> request.set_method(http.Head)
        |> request.set_body(<<>>)
      let checked = router.handle(head_request, runtime)
      Some(
        case
          checked.status,
          attachment_file_window(checked),
          attachment_filesystem.blob_path(config.attachment_directory, key)
        {
          status, Ok(#(offset, length)), Ok(path)
            if status == 200 || status == 206
          ->
            case mist.send_file(path, offset:, limit: Some(length)) {
              Ok(file) -> response.set_body(checked, file)
              Error(_) -> buffered_download(incoming, runtime)
            }
          _, _, _ -> to_mist_response(checked)
        },
      )
    }
    _, _, _ -> None
  }
}

fn attachment_file_window(
  reply: Response(BitArray),
) -> Result(#(Int, Int), Nil) {
  use length_text <- result.try(response.get_header(reply, "content-length"))
  use length <- result.try(int.parse(length_text))
  case reply.status {
    200 if length >= 0 -> Ok(#(0, length))
    206 -> {
      use content_range <- result.try(response.get_header(
        reply,
        "content-range",
      ))
      use unit_and_value <- result.try(string.split_once(content_range, " "))
      use range_and_total <- result.try(string.split_once(unit_and_value.1, "/"))
      use bounds <- result.try(string.split_once(range_and_total.0, "-"))
      use start <- result.try(int.parse(bounds.0))
      use end <- result.try(int.parse(bounds.1))
      case
        unit_and_value.0 == "bytes",
        start >= 0,
        end >= start,
        end - start + 1 == length
      {
        True, True, True, True -> Ok(#(start, length))
        _, _, _, _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn buffered_download(
  incoming: request.Request(mist.Connection),
  runtime: runtime.Runtime,
) -> Response(mist.ResponseData) {
  incoming
  |> request.set_body(<<>>)
  |> router.handle(runtime)
  |> to_mist_response
}

fn prepare_database(path: String) -> Result(Nil, Error) {
  case path == ":memory:" {
    True -> Ok(Nil)
    False ->
      ensure_parent(path)
      |> result.map_error(fn(_) { DatabaseDirectoryError(path) })
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    StorageError(storage.Unavailable(detail)) ->
      "storage unavailable: " <> detail
    StorageError(storage.Conflict(detail)) -> "storage conflict: " <> detail
    StorageError(storage.Corrupt(detail)) -> "storage corrupt: " <> detail
    StorageError(storage.MigrationRequired(version)) ->
      "database migration required: " <> int.to_string(version)
    StorageError(storage.UnsupportedSchema(detail)) ->
      "unsupported database schema: " <> detail
    BrokerStartError(_) -> "live subscription broker could not start"
    HttpStartError(_) -> "HTTP listener could not start"
    Http3StartError(_) -> "HTTP/3 listener could not start"
    DatabaseDirectoryError(path) ->
      "cannot create the database directory for " <> path
    IdentityStartError(identity.Unavailable(detail)) ->
      "identity storage unavailable: " <> detail
    IdentityStartError(identity.Conflict(detail)) ->
      "identity storage conflict: " <> detail
    IdentityStartError(identity.Corrupt(detail)) ->
      "identity storage corrupt: " <> detail
    IdentityStartError(identity.NotFound) -> "identity record not found"
    IdentityStartError(identity.InvalidSetupToken) -> "invalid setup token"
    IdentityStartError(identity.SetupAlreadyComplete) ->
      "server setup is already complete"
    IdentityStartError(identity.InvalidPage) ->
      "identity page configuration is invalid"
    AccessStartError(_) -> "Argon2id password subsystem failed to initialise"
    AttachmentStartError(attachment_store.TooLarge(_, _)) ->
      "invalid attachment size limit"
    AttachmentStartError(attachment_store.QuotaExceeded(_)) ->
      "attachment storage quota is exhausted"
    AttachmentStartError(attachment_store.NotFound) ->
      "attachment storage directory not found"
    AttachmentStartError(attachment_store.InvalidRange) ->
      "invalid attachment storage range"
    AttachmentStartError(attachment_store.InvalidPage) ->
      "invalid attachment storage page"
    AttachmentStartError(attachment_store.Unavailable(detail)) ->
      "attachment storage unavailable: " <> detail
    DeliveryStartError(delivery.NotFound) -> "delivery outbox record not found"
    DeliveryStartError(delivery.Conflict) -> "delivery outbox conflict"
    DeliveryStartError(delivery.LeaseLost) -> "delivery outbox lease lost"
    DeliveryStartError(delivery.InvalidPage) -> "delivery outbox page invalid"
    DeliveryStartError(delivery.Unavailable(detail)) ->
      "delivery outbox unavailable: " <> detail
    WebPushStartError(webpush.InvalidSubscription) ->
      "Web Push subscription configuration is invalid"
    WebPushStartError(webpush.UnknownEndpoint) ->
      "Web Push endpoint is not an allowed push service"
    WebPushStartError(webpush.TooManyTopics) ->
      "Web Push subscription has too many topics"
    WebPushStartError(webpush.TooManySubscriptions) ->
      "Web Push subscriber quota is exhausted"
    WebPushStartError(webpush.NotFound) -> "Web Push subscription was not found"
    WebPushStartError(webpush.Conflict) -> "Web Push subscription conflict"
    WebPushStartError(webpush.Unavailable(detail)) ->
      "Web Push storage unavailable: " <> detail
    RateLimitStartError(rate_limit.Unavailable(detail)) ->
      "rate limiter unavailable: " <> detail
    AuditStartError(audit.InvalidEvent(field)) ->
      "audit configuration produced an invalid " <> field <> " field"
    AuditStartError(audit.InvalidPage) -> "audit page configuration is invalid"
    AuditStartError(audit.Unavailable(detail)) ->
      "audit storage unavailable: " <> detail
    AuditStartError(audit.Corrupt(detail)) ->
      "audit storage corrupt: " <> detail
    SQLiteLockError(sqlite_lock.AlreadyRunning(path)) ->
      "SQLite database "
      <> path
      <> " is already owned by another Notify server; use PostgreSQL for multiple nodes"
    SQLiteLockError(sqlite_lock.Unavailable(detail)) ->
      "SQLite process lock unavailable: " <> detail
  }
}

@external(erlang, "notify_ffi", "ensure_parent")
fn ensure_parent(path: String) -> Result(Nil, Nil)

@external(erlang, "notify_ffi", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int

@external(erlang, "notify_ffi", "mist_http_protocol")
fn mist_http_protocol(connection: mist.Connection) -> String

@external(erlang, "notify_ffi", "shutdown_process")
fn shutdown_process(pid: Pid, timeout_milliseconds: Int) -> Bool

@external(erlang, "notify_ffi", "linked_processes")
fn linked_processes() -> List(Pid)

@external(erlang, "notify_ffi", "shutdown_processes")
fn shutdown_processes(pids: List(Pid), timeout_milliseconds: Int) -> Bool

@external(erlang, "notify_ffi", "set_trap_exits")
fn set_trap_exits(enabled: Bool) -> Bool

@external(erlang, "notify_ffi", "flush_exit_messages")
fn flush_exit_messages() -> Nil
