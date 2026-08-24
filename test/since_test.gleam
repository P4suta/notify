import gleam/option.{None, Some}
import notify/since
import notify/storage

pub fn since_defaults_differ_for_poll_and_live_test() {
  assert since.parse(None, poll: True, now: 1000) == Ok(storage.All)
  assert since.parse(None, poll: False, now: 1000) == Ok(storage.NoneSince)
}

pub fn since_supports_ntfy_keywords_ids_timestamps_and_durations_test() {
  assert since.parse(Some("latest"), poll: True, now: 1000)
    == Ok(storage.Latest)
  assert since.parse(Some("AbCdEf1234"), poll: True, now: 1000)
    == Ok(storage.AfterId("AbCdEf1234"))
  assert since.parse(Some("900"), poll: True, now: 1000)
    == Ok(storage.AfterTime(900))
  assert since.parse(Some("1.5m"), poll: True, now: 1000)
    == Ok(storage.AfterTime(910))
  assert since.parse(Some("INVALID"), poll: True, now: 1000)
    == Error(since.InvalidSince)
}
