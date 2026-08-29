import gleam/erlang/process.{type Pid}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import notify/runtime.{type Runtime}
import notify/service

const claim_batch_size = 100

/// Starts the four independent maintenance lanes under a one-for-one
/// supervisor. A blocked cleanup backend therefore cannot delay due messages
/// or another cleanup dependency.
pub fn start(runtime: Runtime, interval_milliseconds: Int) -> Pid {
  let assert Ok(started) =
    static_supervisor.start(builder(runtime, interval_milliseconds))
  started.pid
}

pub fn supervised(
  runtime: Runtime,
  interval_milliseconds: Int,
) -> supervision.ChildSpecification(Nil) {
  builder(runtime, interval_milliseconds)
  |> static_supervisor.supervised
  |> supervision.map_data(fn(_) { Nil })
}

fn builder(
  runtime: Runtime,
  interval_milliseconds: Int,
) -> static_supervisor.Builder {
  let due_interval = max(1, interval_milliseconds)
  let cleanup_interval = due_interval * 60
  static_supervisor.new(strategy: static_supervisor.OneForOne)
  |> static_supervisor.restart_tolerance(intensity: 10, period: 60)
  |> static_supervisor.add(
    worker(fn() { due_release_loop(runtime, due_interval) }),
  )
  |> static_supervisor.add(
    worker(fn() { message_cleanup_loop(runtime, cleanup_interval) }),
  )
  |> static_supervisor.add(
    worker(fn() { attachment_cleanup_loop(runtime, cleanup_interval) }),
  )
  |> static_supervisor.add(
    worker(fn() { webpush_cleanup_loop(runtime, cleanup_interval) }),
  )
}

fn worker(run: fn() -> Nil) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let pid = process.spawn(run)
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn due_release_loop(runtime: Runtime, interval_milliseconds: Int) -> Nil {
  let _ = service.release_due(runtime, claim_batch_size)
  process.sleep(interval_milliseconds)
  due_release_loop(runtime, interval_milliseconds)
}

fn message_cleanup_loop(runtime: Runtime, interval_milliseconds: Int) -> Nil {
  let runtime.Clock(now) = runtime.clock
  let _ = runtime.storage.cleanup_expired(now())
  process.sleep(interval_milliseconds)
  message_cleanup_loop(runtime, interval_milliseconds)
}

fn attachment_cleanup_loop(
  runtime: Runtime,
  interval_milliseconds: Int,
) -> Nil {
  case runtime.attachments {
    Some(store) -> {
      let runtime.Clock(now) = runtime.clock
      let _ = store.cleanup(now())
      Nil
    }
    None -> Nil
  }
  process.sleep(interval_milliseconds)
  attachment_cleanup_loop(runtime, interval_milliseconds)
}

fn webpush_cleanup_loop(runtime: Runtime, interval_milliseconds: Int) -> Nil {
  case runtime.webpush {
    Some(configured) -> {
      let runtime.Clock(now) = runtime.clock
      let _ = configured.store.remove_expired(now() - 5_184_000)
      Nil
    }
    None -> Nil
  }
  process.sleep(interval_milliseconds)
  webpush_cleanup_loop(runtime, interval_milliseconds)
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
