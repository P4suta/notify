import gleam/string
import notify/sqlite_lock

pub fn sqlite_database_has_one_live_server_owner_test() {
  let path = temporary_path()
  let assert Ok(lock) = sqlite_lock.acquire(path)
  assert sqlite_lock.acquire(path) == Error(sqlite_lock.AlreadyRunning(path))
  sqlite_lock.release(lock)
  let assert Ok(reacquired) = sqlite_lock.acquire(path)
  sqlite_lock.release(reacquired)
}

pub fn in_memory_databases_do_not_need_a_process_lock_test() {
  let assert Ok(first) = sqlite_lock.acquire(":memory:")
  let assert Ok(second) = sqlite_lock.acquire(":memory:")
  sqlite_lock.release(first)
  sqlite_lock.release(second)
}

pub fn windows_tasklist_parser_matches_only_the_pid_column_test() {
  let row = "\"erl.exe\",\"4242\",\"Console\",\"1\",\"42,420 K\"\r\n"
  assert windows_tasklist_has_pid(row, "4242")
  assert !windows_tasklist_has_pid(row, "42")
  assert !windows_tasklist_has_pid(row, "242")
  assert !windows_tasklist_has_pid(
    "INFO: No tasks are running which match the specified criteria.\r\n",
    "4242",
  )
}

fn temporary_path() -> String {
  let assert Ok(directory) = make_temporary_directory()
  string.trim_end(directory) <> "/notify.db"
}

@external(erlang, "notify_ffi", "make_temporary_directory")
fn make_temporary_directory() -> Result(String, Nil)

@external(erlang, "notify_ffi", "sqlite_windows_tasklist_has_pid")
fn windows_tasklist_has_pid(output: String, pid: String) -> Bool
