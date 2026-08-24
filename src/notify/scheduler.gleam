import gleam/erlang/process.{type Pid}
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import notify/runtime.{type Runtime}
import notify/service

const claim_batch_size = 100

/// Starts a linked scheduler loop. Each tick atomically claims due messages
/// through the storage port before broadcasting them, so a failed claim can
/// never produce an uncommitted live notification.
pub fn start(runtime: Runtime, interval_milliseconds: Int) -> Pid {
  process.spawn(fn() { loop(runtime, max(1, interval_milliseconds), 0) })
}

pub fn supervised(
  runtime: Runtime,
  interval_milliseconds: Int,
) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    let pid = start(runtime, interval_milliseconds)
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn loop(runtime: Runtime, interval_milliseconds: Int, tick: Int) -> Nil {
  let _ = service.release_due(runtime, claim_batch_size)
  case tick == 0 {
    True -> {
      let runtime.Clock(now) = runtime.clock
      let current_time = now()
      let _ = runtime.storage.cleanup_expired(current_time)
      case runtime.attachments {
        Some(store) -> {
          let _ = store.cleanup(current_time)
          Nil
        }
        None -> Nil
      }
      case runtime.webpush {
        Some(configured) -> {
          let _ = configured.store.remove_expired(current_time - 5_184_000)
          Nil
        }
        None -> Nil
      }
      Nil
    }
    False -> Nil
  }
  process.sleep(interval_milliseconds)
  loop(runtime, interval_milliseconds, modulo(tick + 1, 60))
}

fn modulo(value: Int, divisor: Int) -> Int {
  value - { value / divisor } * divisor
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
