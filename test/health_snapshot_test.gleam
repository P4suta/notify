import gleam/erlang/process
import gleam/list
import notify/health_snapshot

pub fn independent_health_dependencies_are_probed_in_parallel_test() {
  let started = process.new_subject()
  let finished = process.new_subject()
  let dependency = fn() {
    let release = process.new_subject()
    process.send(started, release)
    let assert Ok(Nil) = process.receive(release, 5000)
    True
  }
  let dependencies =
    health_snapshot.Dependencies(
      storage: dependency,
      attachments: dependency,
      deliveries: dependency,
      webpush: dependency,
      audit: dependency,
      http3: dependency,
    )
  process.spawn(fn() {
    process.send(finished, health_snapshot.probe(dependencies))
  })

  let releases = receive_releases(started, 6, [])
  assert list.length(releases) == 6
  list.each(releases, fn(release) { process.send(release, Nil) })
  let assert Ok(snapshot) = process.receive(finished, 1000)
  assert health_snapshot.ready(snapshot)
}

pub fn health_monitor_shares_a_recent_snapshot_test() {
  let probes = process.new_subject()
  let dependency = fn() {
    process.send(probes, Nil)
    True
  }
  let dependencies =
    health_snapshot.Dependencies(
      storage: dependency,
      attachments: dependency,
      deliveries: dependency,
      webpush: dependency,
      audit: dependency,
      http3: dependency,
    )
  let assert Ok(monitor) = health_snapshot.start(dependencies, 500)
  assert monitor |> health_snapshot.get |> health_snapshot.ready
  receive_probes(probes, 6)
  assert monitor |> health_snapshot.get |> health_snapshot.ready
  assert process.receive(probes, 50) == Error(Nil)
}

fn receive_releases(
  started: process.Subject(process.Subject(Nil)),
  remaining: Int,
  accumulated: List(process.Subject(Nil)),
) -> List(process.Subject(Nil)) {
  case remaining {
    0 -> accumulated
    _ -> {
      let assert Ok(release) = process.receive(started, 1000)
      receive_releases(started, remaining - 1, [release, ..accumulated])
    }
  }
}

fn receive_probes(probes: process.Subject(Nil), remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let assert Ok(Nil) = process.receive(probes, 1000)
      receive_probes(probes, remaining - 1)
    }
  }
}
