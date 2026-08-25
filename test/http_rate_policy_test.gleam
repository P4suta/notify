import gleam/http
import gleam/http/request
import gleam/option.{None, Some}
import notify/http/rate_policy
import notify/rate_limit

pub fn operational_endpoints_do_not_consume_rate_credit_test() {
  let operational_request = fn(path) {
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_body(<<>>)
  }
  assert rate_policy.preflight(operational_request("/healthz"), 16_777_216)
    == []
  assert rate_policy.preflight(operational_request("/icon.svg"), 16_777_216)
    == []
  assert rate_policy.preflight(operational_request("/icon-192.png"), 16_777_216)
    == []
  assert rate_policy.preflight(operational_request("/icon-512.png"), 16_777_216)
    == []
}

pub fn subscriptions_and_publications_use_independent_buckets_test() {
  let subscribe =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/sse")
    |> request.set_body(<<>>)
  assert rate_policy.preflight(subscribe, 16_777_216)
    == [
      rate_policy.Charge(rate_limit.Request, 1),
      rate_policy.Charge(rate_limit.Subscription, 1),
    ]

  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_body(<<>>)
  assert rate_policy.preflight(publish, 16_777_216)
    == [
      rate_policy.Charge(rate_limit.Request, 1),
      rate_policy.Charge(rate_limit.TopicCreation, 1),
    ]

  let json_publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/")
    |> request.set_body(<<>>)
  assert rate_policy.preflight(json_publish, 16_777_216)
    == [
      rate_policy.Charge(rate_limit.Request, 1),
      rate_policy.Charge(rate_limit.TopicCreation, 1),
    ]
}

pub fn bounded_polls_do_not_consume_live_subscription_credit_test() {
  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
  assert rate_policy.preflight(poll, 16_777_216)
    == [rate_policy.Charge(rate_limit.Request, 1)]

  let short_alias =
    poll
    |> request.set_query([#("po", "yes")])
  assert rate_policy.preflight(short_alias, 16_777_216)
    == [rate_policy.Charge(rate_limit.Request, 1)]

  let header_alias =
    poll
    |> request.set_query([])
    |> request.set_header("x-poll", "true")
  assert rate_policy.preflight(header_alias, 16_777_216)
    == [rate_policy.Charge(rate_limit.Request, 1)]
}

pub fn local_attachment_upload_charges_quota_and_mebibytes_test() {
  let upload =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("filename", "report.pdf")
    |> request.set_header("content-length", "1048577")
    |> request.set_body(<<>>)
  assert rate_policy.preflight(upload, 16_777_216)
    == [
      rate_policy.Charge(rate_limit.Request, 1),
      rate_policy.Charge(rate_limit.TopicCreation, 1),
      rate_policy.Charge(rate_limit.AttachmentQuota, 1),
      rate_policy.Charge(rate_limit.AttachmentBandwidth, 2),
    ]

  let chunked =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("filename", "report.pdf")
    |> request.set_body(<<>>)
  assert rate_policy.preflight(chunked, 16_777_216)
    == [
      rate_policy.Charge(rate_limit.Request, 1),
      rate_policy.Charge(rate_limit.TopicCreation, 1),
      rate_policy.Charge(rate_limit.AttachmentQuota, 1),
      rate_policy.Charge(rate_limit.AttachmentBandwidth, 16),
    ]
}

pub fn failed_auth_and_successful_downloads_are_post_charged_test() {
  let download =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/file/alerts/sha256-safe/report.pdf")
    |> request.set_body(<<>>)
  assert rate_policy.after_response(download, 401, None)
    == [
      rate_policy.Charge(rate_limit.AuthFailure, 1),
    ]
  assert rate_policy.after_response(download, 206, Some(1_048_577))
    == [
      rate_policy.Charge(rate_limit.AttachmentBandwidth, 2),
    ]

  let head = request.set_method(download, http.Head)
  assert rate_policy.after_response(head, 200, Some(1_048_577)) == []
}
