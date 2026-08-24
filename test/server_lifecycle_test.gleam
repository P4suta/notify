import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/string
import notify/attachment_store/filesystem
import notify/config
import notify/server
import notify/sqlite_lock

pub fn failed_start_releases_all_owned_processes_and_sqlite_lock_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let directory = string.trim_end(directory)
  let database = directory <> "/notify.db"
  let existing_processes = linked_processes()
  let configuration =
    config.Config(
      ..config.defaults(),
      port: 0,
      bind: "not a valid listener address",
      database_path: database,
      attachment_directory: directory <> "/attachments",
    )

  let assert Error(_) = server.start(configuration)
  let remaining_processes = linked_processes()
  assert list.length(remaining_processes) == list.length(existing_processes)
  assert list.all(remaining_processes, fn(pid) {
    list.contains(existing_processes, pid)
  })

  let assert Ok(lock) = sqlite_lock.acquire(database)
  sqlite_lock.release(lock)
}

@external(erlang, "notify_ffi", "linked_processes")
fn linked_processes() -> List(Pid)
