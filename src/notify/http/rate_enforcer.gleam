//// Transport-neutral rate-limit enforcement for bounded HTTP responses.

import gleam/http.{type Header}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import notify/http/rate_policy
import notify/rate_limit
import notify/runtime

/// Reserve every preflight charge or return the ntfy-compatible rejection.
///
/// Successful reservations return the finite headers that must be attached to
/// the eventual bounded or streaming response head.
pub fn preflight(
  request: Request(body),
  application: runtime.Runtime,
  client_key: String,
  maximum_request_bytes: Int,
) -> Result(List(Header), Response(BitArray)) {
  check(
    rate_policy.preflight(request, maximum_request_bytes),
    application,
    client_key,
  )
}

/// Apply charges only knowable after routing and preserve response headers.
pub fn after_response(
  request: Request(body),
  reply: Response(BitArray),
  application: runtime.Runtime,
  client_key: String,
) -> Response(BitArray) {
  case
    check(
      rate_policy.after_response(request, reply.status, content_length(reply)),
      application,
      client_key,
    )
  {
    Error(rejection) -> rejection
    Ok(headers) -> apply_headers_if_missing(reply, headers)
  }
}

/// Enforce both preflight and post-response charges around bounded routing.
pub fn enforce(
  request: Request(body),
  application: runtime.Runtime,
  client_key: String,
  maximum_request_bytes: Int,
  continue: fn() -> Response(BitArray),
) -> Response(BitArray) {
  case preflight(request, application, client_key, maximum_request_bytes) {
    Error(reply) -> reply
    Ok(headers) -> {
      let reply = continue() |> apply_headers_if_missing(headers)
      after_response(request, reply, application, client_key)
    }
  }
}

fn check(
  charges: List(rate_policy.Charge),
  application: runtime.Runtime,
  client_key: String,
) -> Result(List(Header), Response(BitArray)) {
  case charges, application.rate_limiter {
    [], _ | _, None -> Ok([])
    [rate_policy.Charge(first_bucket, _), ..], Some(limiter) -> {
      let runtime.Clock(now) = application.clock
      let checked_at = now()
      case
        limiter.check_many(
          charges
            |> list.map(fn(charge) {
              let rate_policy.Charge(bucket, cost) = charge
              #(bucket, cost)
            }),
          client_key,
          checked_at,
        )
      {
        Error(_) -> Error(unavailable(first_bucket))
        Ok(decisions) -> decision_headers(decisions, limiter, checked_at)
      }
    }
  }
}

fn decision_headers(
  decisions: List(#(rate_limit.Bucket, rate_limit.Decision)),
  limiter: rate_limit.Limiter,
  checked_at: Int,
) -> Result(List(Header), Response(BitArray)) {
  case first_limited(decisions) {
    Some(#(bucket, retry_after, reset_at)) ->
      Error(
        json_response(
          429,
          "{\"code\":42901,\"http\":429,\"error\":\"limit reached: too many requests\"}",
        )
        |> response.set_header("retry-after", int.to_string(retry_after))
        |> apply_headers(rate_headers(
          limiter.limit(bucket),
          0,
          int.max(1, reset_at - checked_at),
          bucket,
        )),
      )
    None ->
      case decisions {
        [] -> Ok([])
        [#(bucket, rate_limit.Allowed(remaining, reset_at)), ..] ->
          Ok(rate_headers(
            limiter.limit(bucket),
            remaining,
            int.max(0, reset_at - checked_at),
            bucket,
          ))
        [#(_, rate_limit.Limited(..)), ..] -> Ok([])
      }
  }
}

fn first_limited(
  decisions: List(#(rate_limit.Bucket, rate_limit.Decision)),
) -> Option(#(rate_limit.Bucket, Int, Int)) {
  decisions
  |> list.find_map(fn(entry) {
    case entry {
      #(bucket, rate_limit.Limited(retry_after, reset_at)) ->
        Ok(#(bucket, retry_after, reset_at))
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

fn unavailable(bucket: rate_limit.Bucket) -> Response(BitArray) {
  json_response(
    503,
    "{\"code\":50301,\"http\":503,\"error\":\"temporarily unavailable: rate limiter\"}",
  )
  |> response.set_header("retry-after", "1")
  |> response.set_header(
    "x-notify-ratelimit-bucket",
    rate_limit.bucket_name(bucket),
  )
}

fn apply_headers_if_missing(
  reply: Response(BitArray),
  headers: List(Header),
) -> Response(BitArray) {
  case response.get_header(reply, "x-notify-ratelimit-bucket") {
    Ok(_) -> reply
    Error(_) -> apply_headers(reply, headers)
  }
}

fn apply_headers(
  reply: Response(BitArray),
  headers: List(Header),
) -> Response(BitArray) {
  list.fold(headers, reply, fn(reply, header) {
    response.set_header(reply, header.0, header.1)
  })
}

fn rate_headers(
  limit: Int,
  remaining: Int,
  reset_after: Int,
  bucket: rate_limit.Bucket,
) -> List(Header) {
  [
    #("ratelimit-limit", int.to_string(limit)),
    #("ratelimit-remaining", int.to_string(remaining)),
    #("ratelimit-reset", int.to_string(reset_after)),
    #("x-notify-ratelimit-bucket", rate_limit.bucket_name(bucket)),
  ]
}

fn content_length(reply: Response(BitArray)) -> Option(Int) {
  case response.get_header(reply, "content-length") {
    Error(_) -> None
    Ok(value) -> value |> int.parse |> option.from_result
  }
}

fn json_response(status: Int, body: String) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(<<body:utf8>>)
}
