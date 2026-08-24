import gleam/http/request.{type Request}
import gleam/option.{type Option, None, Some}
import gleam/result
import notify/audit
import notify/runtime.{type Runtime}

pub fn append(
  request: Request(body),
  runtime: Runtime,
  actor: String,
  action: audit.Action,
  target: Option(String),
  outcome: audit.Outcome,
  status: Option(Int),
) -> Result(Nil, audit.Error) {
  case runtime.audit {
    None -> Ok(Nil)
    Some(store) -> {
      let runtime.Clock(now) = runtime.clock
      use event <- result.try(audit.new_event(
        occurred_at: now(),
        actor:,
        action:,
        target:,
        outcome:,
        status:,
        client_ip: internal_header(request, "x-notify-client-ip"),
        request_id: internal_header(request, "x-request-id"),
      ))
      store.append(event) |> result.map(fn(_) { Nil })
    }
  }
}

pub fn outcome_for_status(status: Int) -> audit.Outcome {
  case status >= 200 && status <= 299, status == 401 || status == 403 {
    True, _ -> audit.Succeeded
    _, True -> audit.Denied
    _, _ -> audit.Failed
  }
}

fn internal_header(request: Request(body), name: String) -> String {
  case request.get_header(request, name) {
    Ok(value) -> value
    Error(_) -> "unknown"
  }
}
