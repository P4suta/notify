import gleam/http.{Get, Head, Post, Put}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import notify/http/parameter
import notify/rate_limit.{type Bucket}

const mebibyte = 1_048_576

pub type Charge {
  Charge(bucket: Bucket, cost: Int)
}

/// Returns all credits that must be reserved before a request is processed.
/// Operational and immutable asset endpoints remain available under load.
pub fn preflight(
  request: Request(body),
  maximum_request_bytes: Int,
) -> List(Charge) {
  case exempt(request) {
    True -> []
    False -> [
      Charge(rate_limit.Request, 1),
      ..specific_charges(request, maximum_request_bytes)
    ]
  }
}

/// Returns credits that are only knowable after routing, such as a failed
/// authentication or the actual length of a ranged attachment response.
pub fn after_response(
  request: Request(body),
  status: Int,
  content_length: Option(Int),
) -> List(Charge) {
  case status == 401 || status == 403 {
    True -> [Charge(rate_limit.AuthFailure, 1)]
    False ->
      case successful_attachment_download(request, status), content_length {
        True, Some(bytes) -> [
          Charge(rate_limit.AttachmentBandwidth, mebibyte_cost(bytes)),
        ]
        _, _ -> []
      }
  }
}

fn specific_charges(
  request: Request(body),
  maximum_request_bytes: Int,
) -> List(Charge) {
  let subscription = case subscription_attempt(request) {
    True -> [Charge(rate_limit.Subscription, 1)]
    False -> []
  }
  let topic_creation = case publication_attempt(request) {
    True -> [Charge(rate_limit.TopicCreation, 1)]
    False -> []
  }
  let attachment = case local_attachment_upload(request) {
    False -> []
    True -> [
      Charge(rate_limit.AttachmentQuota, 1),
      Charge(
        rate_limit.AttachmentBandwidth,
        upload_cost(request, maximum_request_bytes),
      ),
    ]
  }
  list.flatten([subscription, topic_creation, attachment])
}

fn subscription_attempt(request: Request(body)) -> Bool {
  case request.method, request.path_segments(request) {
    Get, [_, suffix]
      if suffix == "json" || suffix == "raw" || suffix == "sse" || suffix == "ws"
    -> True
    Post, ["v1", "webpush"] -> True
    _, _ -> False
  }
}

fn publication_attempt(request: Request(body)) -> Bool {
  case request.method, request.path_segments(request) {
    Post, [] | Put, [] | Post, [_] | Put, [_] -> True
    Get, [_, action]
      if action == "publish" || action == "send" || action == "trigger"
    -> True
    _, _ -> False
  }
}

fn local_attachment_upload(request: Request(body)) -> Bool {
  case request.method, request.path_segments(request) {
    Post, [_] | Put, [_] ->
      case
        parameter.read(request, ["x-filename", "filename", "file", "f"]),
        parameter.read(request, ["x-attach", "attach", "a"])
      {
        Some(_), None -> True
        _, _ -> False
      }
    _, _ -> False
  }
}

fn successful_attachment_download(request: Request(body), status: Int) -> Bool {
  case request.method, request.path_segments(request), status {
    Get, ["file", _, _, ..], 200 | Get, ["file", _, _, ..], 206 -> True
    Head, _, _ | _, _, _ -> False
  }
}

fn upload_cost(request: Request(body), maximum_request_bytes: Int) -> Int {
  case request.get_header(request, "content-length") {
    Error(_) -> mebibyte_cost(maximum_request_bytes)
    Ok(value) ->
      value
      |> int.parse
      |> result.map(mebibyte_cost)
      |> result.unwrap(mebibyte_cost(maximum_request_bytes))
  }
}

fn mebibyte_cost(bytes: Int) -> Int {
  case bytes > 0 {
    True -> { bytes + mebibyte - 1 } / mebibyte
    False -> 1
  }
}

fn exempt(request: Request(body)) -> Bool {
  case request.method, request.path_segments(request) {
    Get, []
    | Get, ["healthz"]
    | Get, ["readyz"]
    | Get, ["metrics"]
    | Get, ["styles.css"]
    | Get, ["notify_web.js"]
    | Get, ["setup.js"]
    | Get, ["sw.js"]
    | Get, ["manifest.webmanifest"]
    | Get, ["api", "openapi.json"]
    | Get, ["v1", "health"]
    | Head, ["v1", "health"]
    | Get, ["v1", "version"]
    | Get, ["v1", "config"]
    -> True
    _, _ -> False
  }
}
