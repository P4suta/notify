import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import mist
import notify/delivery/relay

pub fn production_mobile_relay_sender_matches_ntfy_poll_contract_test() {
  case getenv("NOTIFY_TEST_NETWORK") {
    Error(_) -> Nil
    Ok(_) -> run_production_mobile_relay_contract()
  }
}

fn run_production_mobile_relay_contract() {
  let received = process.new_subject()
  let assigned_port = process.new_subject()
  let handler = fn(incoming) {
    let assert Ok(incoming) = mist.read_body(incoming, 1024)
    let poll_id = request.get_header(incoming, "x-poll-id")
    let authorization = request.get_header(incoming, "authorization")
    process.send(received, #(
      request.path_segments(incoming),
      poll_id,
      authorization,
      incoming.body,
    ))
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
  }
  let assert Ok(started) =
    mist.new(handler)
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(assigned_port, port) })
    |> mist.start
  let assert Ok(port) = process.receive(assigned_port, 2000)
  let relay.Sender(send) = relay.production_sender()
  let assert Ok(200) =
    send(
      "http://127.0.0.1:" <> int.to_string(port) <> "/safe-topic-hash",
      "tk_upstream",
      "Message001",
    )
  let assert Ok(#(path, poll_id, authorization, body)) =
    process.receive(received, 2000)
  assert path == ["safe-topic-hash"]
  assert poll_id == Ok("Message001")
  assert authorization == Ok("Bearer tk_upstream")
  assert body == <<>>
  process.unlink(started.pid)
  process.send_exit(started.pid)
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
