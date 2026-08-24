import gleam/option.{None}
import notify/attachment_migration
import notify/attachment_store
import notify/attachment_store/memory

pub fn attachment_migration_is_dry_runnable_idempotent_and_source_preserving_test() {
  let assert Ok(source) =
    memory.start(max_file_bytes: 100, max_total_bytes: 200)
  let assert Ok(target) =
    memory.start(max_file_bytes: 100, max_total_bytes: 200)
  let assert Ok(first) =
    source.put(attachment_store.Upload(<<"first":utf8>>, 1000))
  let assert Ok(second) =
    source.put(attachment_store.Upload(<<"second":utf8>>, 2000))

  let assert Ok(preview) =
    attachment_migration.run(source, target, dry_run: True)
  assert preview.scanned == 2
  assert preview.migrated == 2
  assert preview.skipped == 0
  assert preview.bytes == 11
  assert target.list() == Ok([])

  let assert Ok(applied) =
    attachment_migration.run(source, target, dry_run: False)
  assert applied.migrated == 2
  assert target.list() == source.list()
  let assert Ok(again) =
    attachment_migration.run(source, target, dry_run: False)
  assert again.migrated == 0
  assert again.skipped == 2
  assert source.get(first.key, None) |> result_is_ok
  assert source.get(second.key, None) |> result_is_ok
}

pub fn failed_attachment_migration_rolls_back_only_new_target_objects_test() {
  let assert Ok(source) =
    memory.start(max_file_bytes: 100, max_total_bytes: 200)
  let assert Ok(target) = memory.start(max_file_bytes: 100, max_total_bytes: 6)
  let assert Ok(existing) =
    target.put(attachment_store.Upload(<<"old":utf8>>, 5000))
  let assert Ok(_) = source.put(attachment_store.Upload(<<"one":utf8>>, 1000))
  let assert Ok(_) =
    source.put(attachment_store.Upload(<<"too-large":utf8>>, 2000))

  let assert Error(attachment_migration.Destination(_)) =
    attachment_migration.run(source, target, dry_run: False)
  assert target.list() == Ok([existing])
  let assert Ok(source_items) = source.list()
  assert list_length(source_items) == 2
}

fn result_is_ok(value: Result(a, e)) -> Bool {
  case value {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn list_length(values: List(a)) -> Int {
  case values {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}
