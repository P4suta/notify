import gleam/dynamic.{type Dynamic}
import gleam/result

pub type Error {
  AlreadyRunning(String)
  Unavailable(String)
}

pub opaque type Lock {
  Lock(handle: Dynamic)
}

pub fn acquire(path: String) -> Result(Lock, Error) {
  case path {
    ":memory:" -> Ok(Lock(dynamic_nil()))
    _ ->
      acquire_lock(path)
      |> result.map(Lock)
      |> result.map_error(fn(detail) {
        case detail == "already_running" {
          True -> AlreadyRunning(path)
          False -> Unavailable(detail)
        }
      })
  }
}

pub fn release(lock: Lock) -> Nil {
  let Lock(handle) = lock
  release_lock(handle)
}

@external(erlang, "notify_ffi", "sqlite_process_lock")
fn acquire_lock(path: String) -> Result(Dynamic, String)

@external(erlang, "notify_ffi", "sqlite_process_unlock")
fn release_lock(handle: Dynamic) -> Nil

@external(erlang, "notify_ffi", "nil_value")
fn dynamic_nil() -> Dynamic
