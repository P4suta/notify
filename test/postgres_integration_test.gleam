import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import notify/access
import notify/attachment_store
import notify/attachment_store/postgres as attachment_postgres
import notify/audit
import notify/audit/postgres as audit_postgres
import notify/cluster/health as cluster_health
import notify/cluster/postgres_bus
import notify/core/acl
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/delivery
import notify/delivery/postgres as delivery_postgres
import notify/identity
import notify/identity/postgres as identity_postgres
import notify/rate_limit
import notify/storage
import notify/storage/postgres
import notify/webpush as webpush_model
import notify/webpush/postgres as webpush_postgres
import postgleam
import postgleam/config
import postgleam/decode

type TestDatabase {
  TestDatabase(
    configuration: config.Config,
    admin: postgleam.Connection,
    schema: String,
  )
}

fn test_database() -> Result(TestDatabase, Nil) {
  use host <- result.try(getenv("NOTIFY_TEST_POSTGRES_HOST"))
  let port = case getenv("NOTIFY_TEST_POSTGRES_PORT") {
    Ok(value) -> int.parse(value) |> result.unwrap(5432)
    Error(_) -> 5432
  }
  let password = case getenv("NOTIFY_TEST_POSTGRES_PASSWORD") {
    Ok(value) -> value
    Error(_) -> "notify-test-password"
  }
  let base_configuration =
    config.default()
    |> config.host(host)
    |> config.port(port)
    |> config.database("notify")
    |> config.username("notify")
    |> config.password(password)
  let schema = "notify_test_" <> string.lowercase(random_id())
  use admin <- result.try(
    postgleam.connect(base_configuration)
    |> result.map_error(fn(_) { Nil }),
  )
  case postgleam.simple_query(admin, "CREATE SCHEMA " <> schema) {
    Error(_) -> {
      postgleam.disconnect(admin)
      Error(Nil)
    }
    Ok(_) ->
      Ok(TestDatabase(
        configuration: config.extra_parameters(base_configuration, [
          #("search_path", schema),
        ]),
        admin:,
        schema:,
      ))
  }
}

fn drop_test_database(database: TestDatabase) -> Nil {
  let TestDatabase(admin:, schema:, ..) = database
  let assert Ok(_) =
    postgleam.simple_query(admin, "DROP SCHEMA " <> schema <> " CASCADE")
  postgleam.disconnect(admin)
}

fn fixture(id: String, scheduled: Bool, timestamp: Int) -> message.Message {
  let assert Ok(topic) = topic.parse("postgres-contract")
  message.Message(
    id:,
    time: timestamp,
    expires: Some(10_000),
    event: message.MessageEvent,
    topic:,
    message: "message-" <> id,
    title: None,
    priority: message.Default,
    tags: [],
    markdown: False,
    icon: None,
    click: None,
    actions: [],
    attachment: None,
    scheduled:,
    cached: True,
    sequence_id: None,
  )
}

fn fixture_on_topic(
  id: String,
  scheduled: Bool,
  timestamp: Int,
  topic_name: String,
) -> message.Message {
  let assert Ok(parsed_topic) = topic.parse(topic_name)
  message.Message(..fixture(id, scheduled, timestamp), topic: parsed_topic)
}

fn delivery_fixture(id: String, kind: delivery.Kind) -> delivery.NewJob {
  delivery.NewJob(
    id:,
    kind:,
    endpoint: "https://relay.example",
    payload: <<"{}":utf8>>,
    message_id: "PgStore001XY",
    topic_hash: "hash",
    available_at: 100,
  )
}

pub fn postgres_audit_is_shared_and_keyset_paginated_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(first_store) = audit_postgres.start(configuration)
      let assert Ok(second_store) = audit_postgres.start(configuration)
      let assert Ok(first_event) =
        audit.new_event(
          occurred_at: 1000,
          actor: "admin",
          action: audit.AclChange,
          target: Some("jobs-*"),
          outcome: audit.Attempted,
          status: None,
          client_ip: "203.0.113.5",
          request_id: "postgres-audit-1",
        )
      let assert Ok(second_event) =
        audit.new_event(
          occurred_at: 1001,
          actor: "admin",
          action: audit.AclChange,
          target: Some("jobs-*"),
          outcome: audit.Succeeded,
          status: Some(200),
          client_ip: "203.0.113.5",
          request_id: "postgres-audit-1",
        )
      let assert Ok(stored_first) = first_store.append(first_event)
      let assert Ok(stored_second) = second_store.append(second_event)
      assert stored_first.sequence < stored_second.sequence
      let assert Ok(audit.Page([latest], Some(next))) =
        first_store.page(None, 1)
      assert latest.sequence == stored_second.sequence
      let assert Ok(audit.Page([oldest], None)) =
        second_store.page(Some(next), 1)
      assert oldest.sequence == stored_first.sequence
      drop_test_database(database)
    }
  }
}

pub fn postgres_audit_rejects_an_unsupported_schema_before_migration_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(connection) = postgleam.connect(configuration)
      let assert Ok(_) =
        postgleam.simple_query(
          connection,
          "CREATE TABLE notify_audit_log (sequence BIGSERIAL PRIMARY KEY, occurred_at BIGINT NOT NULL)",
        )
      postgleam.disconnect(connection)

      let assert Error(audit.Corrupt(detail)) =
        audit_postgres.start(configuration)
      assert string.contains(detail, "database was not modified")
      drop_test_database(database)
    }
  }
}

pub fn postgres_identity_token_activity_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(identity) = identity_postgres.open_store(configuration)
      let assert Ok(control) = access.managed(identity)
      let assert Ok(index_connection) = postgleam.connect(configuration)
      let assert Ok(1) =
        postgleam.query_one(
          index_connection,
          "SELECT COUNT(*)::bigint FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'notify_access_tokens_user_id'",
          [],
          {
            use count <- decode.element(0, decode.int)
            decode.success(count)
          },
        )
      postgleam.disconnect(index_connection)
      let assert Ok(user) =
        access.add_user(
          control,
          "u_pg_token_contract",
          "pg_token_contract",
          "correct horse battery staple",
          acl.User,
          2000,
        )
      let assert Ok(_) =
        access.add_user(
          control,
          "u_pg_token_contract_z",
          "pg_token_contract_z",
          "correct horse battery staple",
          acl.User,
          2000,
        )
      let assert Ok(identity.Page([first_page_user], True)) =
        access.page_users(control, None, 1)
      assert first_page_user.username == "pg_token_contract"
      let assert Ok(identity.Page([second_page_user], False)) =
        access.page_users(control, Some(first_page_user.username), 1)
      assert second_page_user.username == "pg_token_contract_z"
      let assert Ok(#(created_token, raw_token)) =
        access.create_token(
          control,
          fn() { "tok_pg_token_contract" },
          user.id,
          "postgres-token-contract",
          None,
          2001,
          fn() { "0123456789ABCDEFGHIJKLMNOPQRS" },
        )
      let assert Ok(#(expired_token, expired_raw)) =
        access.create_token(
          control,
          fn() { "tok_pg_expired_contract" },
          user.id,
          "expired-token-contract",
          Some(2000),
          1999,
          fn() { "abcdefghijklmnopqrstuvwxyz012" },
        )
      assert created_token.last_access == None
      assert expired_token.last_access == None
      assert access.authenticate(control, access.Bearer(raw_token), 2003)
        == Ok(acl.Authenticated("pg_token_contract", acl.User))
      assert access.authenticate(control, access.Bearer(raw_token), 2002)
        == Ok(acl.Authenticated("pg_token_contract", acl.User))
      assert access.authenticate(control, access.Bearer(expired_raw), 2003)
        == Error(access.InvalidCredentials)
      let ids = process.new_subject()
      process.send(ids, "tok_pg_token_contract")
      process.send(ids, "tok_pg_recovered_contract")
      let entropies = process.new_subject()
      process.send(entropies, "FFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
      process.send(entropies, "GGGGGGGGGGGGGGGGGGGGGGGGGGGGG")
      let assert Ok(#(recovered, _)) =
        access.create_token(
          control,
          fn() {
            let assert Ok(id) = process.receive(ids, 1000)
            id
          },
          user.id,
          "recovered-token-contract",
          None,
          2004,
          fn() {
            let assert Ok(entropy) = process.receive(entropies, 1000)
            entropy
          },
        )
      assert recovered.id == "tok_pg_recovered_contract"
      let assert Ok([recovered_token, used_token, unused_expired]) =
        access.list_tokens(control, "pg_token_contract")
      assert recovered_token.last_access == None
      assert used_token.last_access == Some(2003)
      assert unused_expired.last_access == None
      let assert Ok(identity.Page([first_page_token], True)) =
        access.page_tokens(control, "pg_token_contract", None, 1)
      assert first_page_token.id == "tok_pg_expired_contract"
      let assert Ok(identity.Page([second_page_token], True)) =
        access.page_tokens(
          control,
          "pg_token_contract",
          Some(first_page_token.id),
          1,
        )
      assert second_page_token.id == "tok_pg_recovered_contract"
      let assert Ok(_) =
        access.grant(control, "pg_token_contract", "jobs-b", acl.ReadOnly)
      let assert Ok(_) =
        access.grant(control, "pg_token_contract", "jobs-a", acl.ReadOnly)
      let assert Ok(identity.Page([first_rule], True)) =
        access.page_grants(control, Some("pg_token_contract"), None, 1)
      assert first_rule.topic_pattern == "jobs-a"
      let assert Ok(identity.Page([second_rule], False)) =
        access.page_grants(
          control,
          Some("pg_token_contract"),
          Some(identity.GrantCursor(
            username: first_rule.username,
            topic_pattern: first_rule.topic_pattern,
          )),
          1,
        )
      assert second_rule.topic_pattern == "jobs-b"
      let assert Ok(_) =
        access.grant(control, "pg_token_contract_z", "jobs-a", acl.ReadOnly)
      let assert Ok(identity.Page(first_rules, True)) =
        access.page_grants(control, None, None, 2)
      assert list.map(first_rules, fn(rule) {
          #(rule.username, rule.topic_pattern)
        })
        == [
          #("pg_token_contract", "jobs-a"),
          #("pg_token_contract", "jobs-b"),
        ]
      let assert Ok(identity.Page([last_rule], False)) =
        access.page_grants(
          control,
          None,
          Some(identity.GrantCursor(
            username: "pg_token_contract",
            topic_pattern: "jobs-b",
          )),
          2,
        )
      assert last_rule.username == "pg_token_contract_z"
      drop_test_database(database)
    }
  }
}

pub fn postgres_storage_pool_recovers_and_serializes_commits_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, admin:, ..) = database
      let assert Ok(adapter_a) = postgres.start(configuration, "node-a")
      let postgres.Adapter(storage: messages, ..) = adapter_a
      assert adapter_a.pool_size == 4
      assert messages.health() == Ok(Nil)

      let assert Ok(_) = postgleam.simple_query(admin, "BEGIN")
      let assert Ok(_) =
        postgleam.query(admin, "SELECT pg_advisory_xact_lock($1::bigint)", [
          postgleam.int(postgres.event_commit_lock()),
        ])
      let locked_commit = process.new_subject()
      process.spawn(fn() {
        process.send(
          locked_commit,
          messages.save(fixture_on_topic(
            "PgLocked01XY",
            False,
            90,
            "postgres-concurrency",
          )),
        )
      })
      assert process.receive(locked_commit, 50) == Error(Nil)
      let assert Ok(_) = postgleam.simple_query(admin, "ROLLBACK")
      assert process.receive(locked_commit, 5000)
        == Ok(
          Ok(fixture_on_topic("PgLocked01XY", False, 90, "postgres-concurrency")),
        )

      let duplicate =
        fixture_on_topic("PgAtomic01XY", False, 90, "postgres-concurrency")
      assert messages.save(duplicate) == Ok(duplicate)
      let assert Error(storage.Conflict(_)) = messages.save(duplicate)
      let assert Ok(1) =
        postgleam.query_one(
          admin,
          "SELECT COUNT(*)::bigint FROM notify_event_log WHERE message_id = $1",
          [postgleam.text(duplicate.id)],
          {
            use count <- decode.element(0, decode.int)
            decode.success(count)
          },
        )

      let concurrent_commits = process.new_subject()
      int.range(from: 1, to: 17, with: Nil, run: fn(_, index) {
        process.spawn(fn() {
          let value =
            fixture_on_topic(
              concurrent_id(index),
              False,
              90 + index,
              "postgres-concurrency",
            )
          process.send(concurrent_commits, messages.save(value))
        })
        Nil
      })
      let commit_results =
        int.range(from: 1, to: 17, with: [], run: fn(results, _) {
          let assert Ok(committed) = process.receive(concurrent_commits, 30_000)
          [committed, ..results]
        })
      assert list.all(commit_results, fn(committed) {
        case committed {
          Ok(_) -> True
          Error(_) -> False
        }
      })

      let assert Ok(_) = postgleam.simple_query(admin, "BEGIN")
      let assert Ok(_) =
        postgleam.query(admin, "SELECT pg_advisory_xact_lock($1::bigint)", [
          postgleam.int(postgres.event_commit_lock()),
        ])
      let interrupted_commit = process.new_subject()
      process.spawn(fn() {
        process.send(
          interrupted_commit,
          messages.save(fixture_on_topic(
            "PgRecover1XY",
            False,
            108,
            "postgres-concurrency",
          )),
        )
      })
      assert process.receive(interrupted_commit, 50) == Error(Nil)
      let assert Ok(1) =
        postgleam.query_one(
          admin,
          "WITH waiting AS (SELECT DISTINCT pid FROM pg_locks WHERE locktype = 'advisory' AND classid = (($1::bigint >> 32)::bigint)::oid AND objid = (($1::bigint & 4294967295)::bigint)::oid AND granted = FALSE), killed AS (SELECT pg_terminate_backend(pid) AS terminated FROM waiting) SELECT COUNT(*)::bigint FROM killed WHERE terminated",
          [postgleam.int(postgres.event_commit_lock())],
          {
            use count <- decode.element(0, decode.int)
            decode.success(count)
          },
        )
      let assert Ok(Error(storage.Unavailable(_))) =
        process.receive(interrupted_commit, 5000)
      let assert Ok(_) = postgleam.simple_query(admin, "ROLLBACK")
      let recovered =
        fixture_on_topic("PgRecover1XY", False, 108, "postgres-concurrency")
      assert messages.save(recovered) == Ok(recovered)
      assert messages.health() == Ok(Nil)

      drop_test_database(database)
    }
  }
}

pub fn postgres_storage_event_replay_and_paging_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(adapter_a) = postgres.start(configuration, "node-a")
      let postgres.Adapter(storage: messages, ..) = adapter_a

      let first = fixture("PgStore001XY", False, 100)
      let delayed = fixture("PgDelay001XY", True, 200)
      assert messages.save(first) == Ok(first)
      assert messages.save(delayed) == Ok(delayed)
      let assert Ok(topic) = topic.parse("postgres-contract")
      let assert Ok(before) =
        messages.query(storage.Query(
          topics: [topic],
          since: storage.All,
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.map(before, fn(value) { value.id }) == ["PgStore001XY"]
      let assert Ok(released) = messages.release_due(200, 10)
      assert list.map(released, fn(value) { value.id }) == ["PgDelay001XY"]

      let expired =
        message.Message(
          ..fixture("PgExpire01XY", False, 109),
          expires: Some(110),
        )
      assert messages.save(expired) == Ok(expired)

      let assert Ok(adapter_b) = postgres.start(configuration, "node-b")
      let postgres.Adapter(fetch_events:, ack_events:, ..) = adapter_b
      let assert Ok(events) = fetch_events("node-b", 100)
      assert list.any(events, fn(event) { event.message.id == "PgStore001XY" })
      let assert Ok(last) = list.last(events)
      assert ack_events("node-b", last.sequence) == Ok(Nil)
      assert fetch_events("node-b", 100) == Ok([])

      let assert Ok(before_cleanup) = messages.stats()
      assert messages.cleanup_expired(110) == Ok(1)
      let assert Ok(after_cleanup) = messages.stats()
      assert after_cleanup.messages == before_cleanup.messages - 1
      assert after_cleanup.events == before_cleanup.events - 1

      save_page_fixtures(messages, 1, 260)
      let assert Ok(page_topic) = topic.parse("postgres-page")
      let assert Ok(pages) =
        messages.query(storage.Query(
          topics: [page_topic],
          since: storage.All,
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.length(pages) == 260
      assert list.first(pages) == Ok(page_fixture(1))
      assert list.last(pages) == Ok(page_fixture(260))
      let assert Ok(after_page) =
        messages.query(storage.Query(
          topics: [page_topic],
          since: storage.AfterId(page_id(256)),
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.length(after_page) == 4
      assert list.first(after_page) == Ok(page_fixture(257))

      let attachment_key = string.repeat("a", times: 64)
      let attached =
        message.Message(
          ..fixture("PgAttach01XY", False, 300),
          attachment: Some(message.Attachment(
            name: "report.txt",
            url: "https://notify.example/file/postgres-contract/"
              <> attachment_key
              <> "/report.txt",
            mime_type: Some("text/plain"),
            size: Some(12),
            expires: Some(400),
          )),
        )
      assert messages.save(attached) == Ok(attached)
      assert messages.has_attachment(topic, attachment_key) == Ok(True)
      let assert Ok(other_topic) = topic.parse("other")
      assert messages.has_attachment(other_topic, attachment_key) == Ok(False)

      drop_test_database(database)
    }
  }
}

pub fn postgres_cluster_health_is_bounded_and_uses_database_time_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(adapter) = postgres.start(configuration, "node-local")
      let postgres.Adapter(
        storage: messages,
        ack_events:,
        cluster_health: monitor,
        ..,
      ) = adapter
      let first =
        fixture_on_topic("PgHealth01XY", False, 350, "postgres-health")
      let second =
        fixture_on_topic("PgHealth02XY", False, 351, "postgres-health")
      assert messages.save(first) == Ok(first)
      assert messages.save(second) == Ok(second)
      assert ack_events("node-a", 1) == Ok(Nil)
      assert ack_events("node-b", 0) == Ok(Nil)
      let assert Ok(connection) = postgleam.connect(configuration)
      let assert Ok(_) =
        postgleam.query(
          connection,
          "UPDATE notify_node_cursors SET updated_at = now() - INTERVAL '8 days' WHERE node_id = $1",
          [postgleam.text("node-b")],
        )
      postgleam.disconnect(connection)

      assert monitor.inspect(None, 0) == Error(cluster_health.InvalidPage)
      assert monitor.inspect(None, 101) == Error(cluster_health.InvalidPage)
      let assert Ok(first_page) = monitor.inspect(None, 1)
      assert first_page.local_node_id == "node-local"
      assert first_page.event_head == 2
      assert first_page.database_time > 0
      assert first_page.cursor_count == 2
      assert first_page.stale_nodes == 1
      let assert cluster_health.Page([node_a], True) = first_page.nodes
      assert node_a.node_id == "node-a"
      assert node_a.sequence == 1
      assert node_a.stale == False

      let assert Ok(second_page) = monitor.inspect(Some("node-a"), 1)
      let assert cluster_health.Page([node_b], False) = second_page.nodes
      assert node_b.node_id == "node-b"
      assert node_b.sequence == 0
      assert node_b.stale == True
      assert node_b.updated_at
        <= second_page.database_time - cluster_health.stale_after_seconds
      drop_test_database(database)
    }
  }
}

pub fn postgres_cluster_bus_recovers_listener_and_ignores_duplicate_wakes_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      process.trap_exits(True)
      let TestDatabase(configuration:, admin:, ..) = database
      let config.Config(extra_parameters:, ..) = configuration
      let listener_name = "notify-fault-" <> string.lowercase(random_id())
      let listener_configuration =
        config.extra_parameters(
          configuration,
          list.append(extra_parameters, [
            #("application_name", listener_name),
          ]),
        )
      let assert Ok(origin) = postgres.start(configuration, "fault-origin")
      let assert Ok(receiver) = postgres.start(configuration, "fault-receiver")
      let postgres.Adapter(storage: origin_messages, ..) = origin
      let deliveries = process.new_subject()
      let listener =
        postgres_bus.start(
          listener_configuration,
          receiver,
          "fault-receiver",
          fn(value) {
            process.send(deliveries, value.id)
            Ok(Nil)
          },
        )

      let assert Ok(first_listener_pid) =
        wait_for_listener_pid(admin, listener_name, 0, 100)
      let first =
        fixture_on_topic("PgFault001XY", False, 400, "postgres-cluster-fault")
      assert origin_messages.save(first) == Ok(first)
      assert process.receive(deliveries, 10_000) == Ok(first.id)
      send_duplicate_wakes(admin)
      assert process.receive(deliveries, 1500) == Error(Nil)

      let assert Ok(True) =
        postgleam.query_one(
          admin,
          "SELECT pg_terminate_backend($1)",
          [postgleam.int(first_listener_pid)],
          {
            use terminated <- decode.element(0, decode.bool)
            decode.success(terminated)
          },
        )
      let second =
        fixture_on_topic("PgFault002XY", False, 401, "postgres-cluster-fault")
      assert origin_messages.save(second) == Ok(second)
      let assert Ok(second_listener_pid) =
        wait_for_listener_pid(admin, listener_name, first_listener_pid, 100)
      assert second_listener_pid != first_listener_pid
      assert process.receive(deliveries, 10_000) == Ok(second.id)
      send_duplicate_wakes(admin)
      assert process.receive(deliveries, 1500) == Error(Nil)

      process.kill(listener)
      assert wait_for_process_stop(listener, 100)
      process.trap_exits(False)
      drop_test_database(database)
    }
  }
}

pub fn postgres_three_node_bus_catches_up_after_actor_restart_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      process.trap_exits(True)
      let TestDatabase(configuration:, ..) = database
      let assert Ok(cursor_connection) = postgleam.connect(configuration)
      let assert Ok(adapter_a) = postgres.start(configuration, "cluster-a")
      let assert Ok(adapter_b) = postgres.start(configuration, "cluster-b")
      let assert Ok(adapter_c) = postgres.start(configuration, "cluster-c")
      let postgres.Adapter(storage: messages_a, ..) = adapter_a
      let postgres.Adapter(storage: messages_c, ..) = adapter_c
      let deliveries_a = process.new_subject()
      let deliveries_b = process.new_subject()
      let deliveries_c = process.new_subject()
      let bus_a =
        postgres_bus.start(configuration, adapter_a, "cluster-a", fn(value) {
          process.send(deliveries_a, value.id)
          Ok(Nil)
        })
      let bus_b =
        postgres_bus.start(configuration, adapter_b, "cluster-b", fn(value) {
          process.send(deliveries_b, value.id)
          Ok(Nil)
        })
      let bus_c =
        postgres_bus.start(configuration, adapter_c, "cluster-c", fn(value) {
          process.send(deliveries_c, value.id)
          Ok(Nil)
        })

      let first =
        fixture_on_topic("PgNode001AXY", False, 500, "postgres-three-node")
      let second =
        fixture_on_topic("PgNode002CXY", False, 501, "postgres-three-node")
      assert messages_a.save(first) == Ok(first)
      assert messages_c.save(second) == Ok(second)
      assert process.receive(deliveries_a, 10_000) == Ok(first.id)
      assert process.receive(deliveries_a, 10_000) == Ok(second.id)
      assert process.receive(deliveries_b, 10_000) == Ok(first.id)
      assert process.receive(deliveries_b, 10_000) == Ok(second.id)
      assert process.receive(deliveries_c, 10_000) == Ok(first.id)
      assert process.receive(deliveries_c, 10_000) == Ok(second.id)
      assert process.receive(deliveries_a, 500) == Error(Nil)
      assert process.receive(deliveries_b, 500) == Error(Nil)
      assert process.receive(deliveries_c, 500) == Error(Nil)
      assert wait_for_node_cursor(cursor_connection, "cluster-b", 2, 100)

      process.kill(bus_b)
      assert wait_for_process_stop(bus_b, 100)
      let third =
        fixture_on_topic("PgNode003AXY", False, 502, "postgres-three-node")
      let fourth =
        fixture_on_topic("PgNode004CXY", False, 503, "postgres-three-node")
      assert messages_a.save(third) == Ok(third)
      assert messages_c.save(fourth) == Ok(fourth)
      assert process.receive(deliveries_a, 10_000) == Ok(third.id)
      assert process.receive(deliveries_a, 10_000) == Ok(fourth.id)
      assert process.receive(deliveries_c, 10_000) == Ok(third.id)
      assert process.receive(deliveries_c, 10_000) == Ok(fourth.id)
      assert process.receive(deliveries_b, 1500) == Error(Nil)

      let restarted_b =
        postgres_bus.start(configuration, adapter_b, "cluster-b", fn(value) {
          process.send(deliveries_b, value.id)
          Ok(Nil)
        })
      assert process.receive(deliveries_b, 10_000) == Ok(third.id)
      assert process.receive(deliveries_b, 10_000) == Ok(fourth.id)
      assert process.receive(deliveries_b, 1500) == Error(Nil)
      assert wait_for_node_cursor(cursor_connection, "cluster-b", 4, 100)

      process.kill(bus_a)
      process.kill(restarted_b)
      process.kill(bus_c)
      assert wait_for_process_stop(bus_a, 100)
      assert wait_for_process_stop(restarted_b, 100)
      assert wait_for_process_stop(bus_c, 100)
      process.trap_exits(False)
      postgleam.disconnect(cursor_connection)
      drop_test_database(database)
    }
  }
}

pub fn postgres_identity_setup_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database

      let assert Ok(identity_postgres.Started(identity, Some(setup_token))) =
        identity_postgres.start(configuration, fn() { 1000 }, fn() {
          "abcdefghijklmnopqrstuvwxyz123"
        })
      assert identity.setup_required() == Ok(True)
      let assert Ok(control) = access.managed(identity)
      let assert Ok(_) =
        access.complete_setup(
          control,
          setup_token,
          "u_pg_admin",
          "pg-admin",
          "correct horse battery staple",
          acl.Deny,
          1001,
        )

      drop_test_database(database)
    }
  }
}

pub fn postgres_attachment_streaming_and_quota_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database

      let assert Ok(blobs) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 10,
          max_total_bytes: 20,
        )
      let assert Ok(stored) =
        blobs.put(attachment_store.Upload(<<"abcdef":utf8>>, expires: 100))
      let assert Ok(partial) =
        blobs.get(
          stored.key,
          Some(attachment_store.ByteRange(start: 1, end: 3)),
        )
      assert partial.data == <<"bcd":utf8>>
      let assert Ok(upload) =
        blobs.begin(attachment_store.BeginUpload(expires: 100))
      assert blobs.write(upload, <<"gh":utf8>>)
        == Ok(attachment_store.Progress(bytes_written: 2))
      assert blobs.write(upload, <<"ijkl":utf8>>)
        == Ok(attachment_store.Progress(bytes_written: 6))
      let assert Ok(streamed) = blobs.finish(upload)
      assert streamed.key == attachment_store.content_key(<<"ghijkl":utf8>>)
      let assert Ok(streamed_download) = blobs.get(streamed.key, None)
      assert streamed_download.data == <<"ghijkl":utf8>>
      let assert Ok(empty_upload) =
        blobs.begin(attachment_store.BeginUpload(expires: 100))
      let assert Ok(empty) = blobs.finish(empty_upload)
      assert empty.size == 0
      let assert Ok(empty_download) = blobs.get(empty.key, None)
      assert empty_download.data == <<>>
      let assert Ok(aborted) =
        blobs.begin(attachment_store.BeginUpload(expires: 100))
      let assert Ok(_) = blobs.write(aborted, <<"discard":utf8>>)
      assert blobs.abort(aborted) == Ok(Nil)
      assert blobs.finish(aborted) == Error(attachment_store.NotFound)
      assert blobs.cleanup(100) == Ok(3)

      let assert Ok(chunked_blobs) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 2_000_000,
          max_total_bytes: 3_000_000,
        )
      let large =
        string.repeat("x", times: 1_048_577)
        |> bit_array.from_string
      let assert Ok(chunked_upload) =
        chunked_blobs.begin(attachment_store.BeginUpload(expires: 200))
      let assert Ok(_) = chunked_blobs.write(chunked_upload, large)
      let assert Ok(chunked) = chunked_blobs.finish(chunked_upload)
      assert chunked.size == 1_048_577
      let assert Ok(chunk_boundary) =
        chunked_blobs.get(
          chunked.key,
          Some(attachment_store.ByteRange(1_048_575, 1_048_576)),
        )
      assert chunk_boundary.data == <<"xx":utf8>>
      assert chunked_blobs.cleanup(200) == Ok(1)

      let assert Ok(quota_a) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 10,
          max_total_bytes: 10,
        )
      let assert Ok(quota_b) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 10,
          max_total_bytes: 10,
        )
      let assert Ok(quota_first) =
        quota_a.begin(attachment_store.BeginUpload(expires: 300))
      let assert Ok(quota_second) =
        quota_b.begin(attachment_store.BeginUpload(expires: 300))
      let assert Ok(_) = quota_a.write(quota_first, <<"123456":utf8>>)
      let assert Ok(_) = quota_b.write(quota_second, <<"abcdef":utf8>>)
      let assert Ok(_) = quota_a.finish(quota_first)
      assert quota_b.finish(quota_second)
        == Error(attachment_store.QuotaExceeded(10))
      assert quota_a.cleanup(300) == Ok(1)

      let assert Ok(orphan) =
        quota_a.begin(attachment_store.BeginUpload(
          expires: unix_seconds() + 7200,
        ))
      let assert Ok(_) = quota_a.write(orphan, <<"orphan":utf8>>)
      let assert Ok(_) = quota_a.cleanup(unix_seconds() + 3601)
      assert quota_a.finish(orphan) == Error(attachment_store.NotFound)

      let assert Ok(page_blobs) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 20,
          max_total_bytes: 100,
        )
      let assert Ok(first_page_blob) =
        page_blobs.put(attachment_store.Upload(<<"page-a":utf8>>, 300))
      let assert Ok(second_page_blob) =
        page_blobs.put(attachment_store.Upload(<<"page-b":utf8>>, 301))
      let assert Ok(third_page_blob) =
        page_blobs.put(attachment_store.Upload(<<"page-c":utf8>>, 302))
      let expected_page_blobs =
        [first_page_blob, second_page_blob, third_page_blob]
        |> list.sort(fn(left, right) { string.compare(left.key, right.key) })
      let assert Ok(attachment_store.Page(first_page, True)) =
        page_blobs.page(None, 2)
      assert first_page == list.take(expected_page_blobs, 2)
      let assert Ok(page_cursor) = list.last(first_page)
      let assert Ok(attachment_store.Page(second_page, False)) =
        page_blobs.page(Some(page_cursor.key), 2)
      assert second_page == list.drop(expected_page_blobs, 2)
      assert page_blobs.page(None, 0) == Error(attachment_store.InvalidPage)
      assert page_blobs.page(None, 101) == Error(attachment_store.InvalidPage)
      assert page_blobs.page(Some("invalid"), 2)
        == Error(attachment_store.InvalidPage)
      assert page_blobs.cleanup(302) == Ok(3)

      drop_test_database(database)
    }
  }
}

pub fn postgres_delivery_webpush_and_rate_limit_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database

      let assert Ok(outbox) = delivery_postgres.start(configuration)
      let assert Ok(index_connection) = postgleam.connect(configuration)
      let assert Ok(1) =
        postgleam.query_one(
          index_connection,
          "SELECT COUNT(*)::bigint FROM pg_indexes WHERE schemaname = current_schema() AND indexname = 'notify_delivery_outbox_kind_id'",
          [],
          {
            use count <- decode.element(0, decode.int)
            decode.success(count)
          },
        )
      postgleam.disconnect(index_connection)
      let assert Ok(_) =
        outbox.enqueue(delivery_fixture("postgres-job", delivery.MobileRelay))
      let assert Ok([claimed]) =
        outbox.claim(delivery.MobileRelay, "node-a", 100, 30, 1)
      assert claimed.lease_until == Some(130)
      let assert Ok(dead) =
        outbox.fail(claimed.id, "node-a", 101, "HTTP 503", 1, 10)
      assert dead.state == delivery.DeadLetter
      let assert Ok(delivery_stats) = outbox.stats()
      assert delivery_stats.mobile_relay_dead_letter == 1
      let assert Ok(requeued) = outbox.requeue(claimed.id, 200)
      assert requeued.state == delivery.Pending
      assert requeued.attempts == 0
      let assert Ok([claimed_again]) =
        outbox.claim(delivery.MobileRelay, "node-b", 200, 30, 1)
      let assert Ok(_) =
        outbox.fail(claimed_again.id, "node-b", 201, "HTTP 503", 1, 10)
      assert outbox.purge(claimed.id) == Ok(Nil)
      assert outbox.list(delivery.MobileRelay) == Ok([])

      list.each(
        [
          delivery_fixture("page-c", delivery.MobileRelay),
          delivery_fixture("page-a", delivery.MobileRelay),
          delivery_fixture("page-b", delivery.WebPush),
        ],
        fn(job) {
          let assert Ok(_) = outbox.enqueue(job)
        },
      )
      let assert Ok(delivery.Page([first_job, second_job], True)) =
        outbox.page(None, None, 2)
      assert [first_job.id, second_job.id] == ["page-a", "page-b"]
      let assert Ok(delivery.Page([last_job], False)) =
        outbox.page(None, Some(second_job.id), 2)
      assert last_job.id == "page-c"
      let assert Ok(delivery.Page([first_relay], True)) =
        outbox.page(Some(delivery.MobileRelay), None, 1)
      assert first_relay.id == "page-a"
      let assert Ok(delivery.Page([second_relay], False)) =
        outbox.page(Some(delivery.MobileRelay), Some(first_relay.id), 1)
      assert second_relay.id == "page-c"
      assert outbox.page(None, None, 0) == Error(delivery.InvalidPage)
      assert outbox.page(None, None, 101) == Error(delivery.InvalidPage)

      let assert Ok(webpush_store) =
        webpush_postgres.start(configuration, max_endpoints_per_ip: 10)
      let endpoint =
        "https://updates.push.services.mozilla.com/wpush/v2/postgres-contract"
      assert webpush_store.remove_endpoint(endpoint) == Ok(Nil)
      let assert Ok(saved_subscription) =
        webpush_store.upsert(webpush_model.NewSubscription(
          id: "wps_postgres",
          endpoint:,
          auth: "kSC3T8aN1JCQxxPdrFLrZg",
          p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
          topics: ["postgres-contract"],
          user_id: None,
          subscriber_ip: "192.0.2.10",
          now: 100,
        ))
      assert saved_subscription.id == "wps_postgres"
      let assert Ok([pg_subscription]) =
        webpush_store.for_topic("postgres-contract")
      assert pg_subscription.endpoint == endpoint
      assert webpush_store.remove_endpoint(endpoint) == Ok(Nil)

      let rate_policies =
        rate_limit.Policies(
          requests: 2,
          subscriptions: 1,
          topic_creations: 7,
          auth_failures: 1,
          attachment_mebibytes: 4,
          attachment_uploads: 1,
        )
      let assert Ok(limiter_a) =
        rate_limit.postgres_with_policies(
          configuration,
          rate_policies,
          window_seconds: 60,
        )
      let assert Ok(limiter_b) =
        rate_limit.postgres_with_policies(
          configuration,
          rate_policies,
          window_seconds: 60,
        )
      let checked_at = unix_seconds()
      let client_key = "distributed-contract-" <> int.to_string(checked_at)
      assert limiter_a.check(rate_limit.Request, client_key, checked_at, 1)
        == Ok(rate_limit.Allowed(remaining: 1, reset_at: checked_at + 30))
      assert limiter_b.check(rate_limit.Request, client_key, checked_at, 1)
        == Ok(rate_limit.Allowed(remaining: 0, reset_at: checked_at + 60))
      assert limiter_a.check(rate_limit.Request, client_key, checked_at, 1)
        == Ok(rate_limit.Limited(retry_after: 30, reset_at: checked_at + 60))
      assert limiter_b.check(rate_limit.Subscription, client_key, checked_at, 1)
        == Ok(rate_limit.Allowed(remaining: 0, reset_at: checked_at + 60))
      assert limiter_b.check(
          rate_limit.AttachmentBandwidth,
          client_key,
          checked_at,
          5,
        )
        == Ok(rate_limit.Limited(retry_after: 60, reset_at: checked_at + 60))

      let batch_key = client_key <> "-batch"
      assert limiter_a.check_many(
          [
            #(rate_limit.Request, 1),
            #(rate_limit.Subscription, 2),
            #(rate_limit.TopicCreation, 1),
          ],
          batch_key,
          checked_at,
        )
        == Ok([
          #(
            rate_limit.Request,
            rate_limit.Allowed(remaining: 1, reset_at: checked_at + 30),
          ),
          #(
            rate_limit.Subscription,
            rate_limit.Limited(retry_after: 60, reset_at: checked_at + 60),
          ),
        ])
      assert limiter_b.check(rate_limit.TopicCreation, batch_key, checked_at, 7)
        == Ok(rate_limit.Allowed(remaining: 0, reset_at: checked_at + 60))

      let concurrent_key = client_key <> "-concurrent"
      let replies = process.new_subject()
      list.repeat(limiter_a, times: 16)
      |> list.append(list.repeat(limiter_b, times: 16))
      |> list.each(fn(limiter) {
        process.spawn(fn() {
          process.send(
            replies,
            limiter.check(
              rate_limit.TopicCreation,
              concurrent_key,
              checked_at,
              1,
            ),
          )
        })
      })
      let decisions = receive_rate_decisions(replies, 32, [])
      let allowed =
        decisions
        |> list.filter(fn(decision) {
          case decision {
            Ok(rate_limit.Allowed(..)) -> True
            _ -> False
          }
        })
        |> list.length
      assert allowed == 7
      drop_test_database(database)
    }
  }
}

pub fn postgres_delivery_lease_expiry_and_competing_claims_contract_test() {
  case test_database() {
    Error(_) -> Nil
    Ok(database) -> {
      let TestDatabase(configuration:, ..) = database
      let assert Ok(outbox_a) = delivery_postgres.start(configuration)
      let assert Ok(outbox_b) = delivery_postgres.start(configuration)
      let assert Ok(_) =
        outbox_a.enqueue(delivery_fixture("lease-expiry", delivery.MobileRelay))

      let assert Ok([original]) =
        outbox_a.claim(delivery.MobileRelay, "node-a", 100, 30, 1)
      assert original.lease_owner == Some("node-a")
      assert outbox_b.claim(delivery.MobileRelay, "node-b", 129, 30, 1)
        == Ok([])
      let assert Ok([reclaimed]) =
        outbox_b.claim(delivery.MobileRelay, "node-b", 130, 30, 1)
      assert reclaimed.id == original.id
      assert reclaimed.attempts == 0
      assert reclaimed.lease_owner == Some("node-b")
      assert outbox_a.complete(original.id, "node-a")
        == Error(delivery.LeaseLost)
      assert outbox_b.complete(reclaimed.id, "node-b") == Ok(Nil)

      int.range(from: 1, to: 33, with: Nil, run: fn(_, index) {
        let assert Ok(_) =
          outbox_a.enqueue(delivery_fixture(
            "lease-race-" <> int.to_string(index),
            delivery.MobileRelay,
          ))
        Nil
      })
      let claims = process.new_subject()
      process.spawn(fn() {
        process.send(
          claims,
          outbox_a.claim(delivery.MobileRelay, "node-a", 200, 30, 16),
        )
      })
      process.spawn(fn() {
        process.send(
          claims,
          outbox_b.claim(delivery.MobileRelay, "node-b", 200, 30, 16),
        )
      })
      let assert Ok(Ok(first_claim)) = process.receive(claims, 30_000)
      let assert Ok(Ok(second_claim)) = process.receive(claims, 30_000)
      assert list.length(first_claim) == 16
      assert list.length(second_claim) == 16
      let claimed_ids =
        list.append(first_claim, second_claim)
        |> list.map(fn(job) { job.id })
      assert list.length(claimed_ids) == 32
      assert list.length(list.unique(claimed_ids)) == 32

      drop_test_database(database)
    }
  }
}

fn receive_rate_decisions(subject, remaining: Int, accumulated) {
  case remaining {
    0 -> accumulated
    _ -> {
      let assert Ok(decision) = process.receive(subject, 30_000)
      receive_rate_decisions(subject, remaining - 1, [decision, ..accumulated])
    }
  }
}

fn wait_for_listener_pid(
  admin: postgleam.Connection,
  application_name: String,
  excluded_pid: Int,
  remaining: Int,
) -> Result(Int, Nil) {
  case remaining {
    0 -> Error(Nil)
    _ ->
      case
        postgleam.query_one(
          admin,
          "SELECT COALESCE(MAX(pid), 0)::bigint FROM pg_stat_activity WHERE application_name = $1 AND pid <> $2",
          [postgleam.text(application_name), postgleam.int(excluded_pid)],
          {
            use pid <- decode.element(0, decode.int)
            decode.success(pid)
          },
        )
      {
        Ok(pid) if pid > 0 -> Ok(pid)
        _ -> {
          process.sleep(100)
          wait_for_listener_pid(
            admin,
            application_name,
            excluded_pid,
            remaining - 1,
          )
        }
      }
  }
}

fn wait_for_node_cursor(
  connection: postgleam.Connection,
  node_id: String,
  minimum_sequence: Int,
  remaining: Int,
) -> Bool {
  case remaining {
    0 -> False
    _ ->
      case
        postgleam.query_one(
          connection,
          "SELECT COALESCE((SELECT sequence FROM notify_node_cursors WHERE node_id = $1), -1)::bigint",
          [postgleam.text(node_id)],
          {
            use sequence <- decode.element(0, decode.int)
            decode.success(sequence)
          },
        )
      {
        Ok(sequence) if sequence >= minimum_sequence -> True
        _ -> {
          process.sleep(100)
          wait_for_node_cursor(
            connection,
            node_id,
            minimum_sequence,
            remaining - 1,
          )
        }
      }
  }
}

fn send_duplicate_wakes(admin: postgleam.Connection) -> Nil {
  let assert Ok(_) =
    postgleam.query(admin, "SELECT pg_notify('notify_events', $1)", [
      postgleam.text("duplicate-a"),
    ])
  let assert Ok(_) =
    postgleam.query(admin, "SELECT pg_notify('notify_events', $1)", [
      postgleam.text("duplicate-b"),
    ])
  Nil
}

fn wait_for_process_stop(pid: process.Pid, remaining: Int) -> Bool {
  case process.is_alive(pid), remaining {
    False, _ -> True
    True, 0 -> False
    True, _ -> {
      process.sleep(50)
      wait_for_process_stop(pid, remaining - 1)
    }
  }
}

fn save_page_fixtures(store: storage.Storage, current: Int, count: Int) -> Nil {
  case current > count {
    True -> Nil
    False -> {
      let value = page_fixture(current)
      assert store.save(value) == Ok(value)
      save_page_fixtures(store, current + 1, count)
    }
  }
}

fn page_fixture(index: Int) -> message.Message {
  let assert Ok(page_topic) = topic.parse("postgres-page")
  message.Message(..fixture(page_id(index), False, index), topic: page_topic)
}

fn page_id(index: Int) -> String {
  "P" <> string.pad_start(int.to_string(index), to: 11, with: "0")
}

fn concurrent_id(index: Int) -> String {
  "C" <> string.pad_start(int.to_string(index), to: 11, with: "0")
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int

@external(erlang, "notify_ffi", "random_id")
fn random_id() -> String
