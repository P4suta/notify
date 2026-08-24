import notify/core/delay

pub fn resolves_relative_delay_units_test() {
  assert delay.resolve("10m", now: 1000) == Ok(1600)
  assert delay.resolve("2 hours", now: 1000) == Ok(8200)
  assert delay.resolve("1d", now: 1000) == Ok(87_400)
}

pub fn accepts_future_unix_timestamp_test() {
  assert delay.resolve("2000", now: 1000) == Ok(2000)
}

pub fn rejects_past_or_malformed_delay_test() {
  assert delay.resolve("999", now: 1000) == Error(delay.NotInFuture)
  assert delay.resolve("eventually", now: 1000) == Error(delay.InvalidDelay)
  assert delay.resolve("0m", now: 1000) == Error(delay.NotInFuture)
}

pub fn every_documented_duration_alias_has_the_exact_multiplier_test() {
  let now = 1000
  assert delay.resolve("2seconds", now:) == Ok(1002)
  assert delay.resolve("2second", now:) == Ok(1002)
  assert delay.resolve("2secs", now:) == Ok(1002)
  assert delay.resolve("2sec", now:) == Ok(1002)
  assert delay.resolve("2minutes", now:) == Ok(1120)
  assert delay.resolve("2minute", now:) == Ok(1120)
  assert delay.resolve("2mins", now:) == Ok(1120)
  assert delay.resolve("2min", now:) == Ok(1120)
  assert delay.resolve("2hours", now:) == Ok(8200)
  assert delay.resolve("2hour", now:) == Ok(8200)
  assert delay.resolve("2hrs", now:) == Ok(8200)
  assert delay.resolve("2hr", now:) == Ok(8200)
  assert delay.resolve("2days", now:) == Ok(173_800)
  assert delay.resolve("2day", now:) == Ok(173_800)
  assert delay.resolve("2s", now:) == Ok(1002)
  assert delay.resolve("2m", now:) == Ok(1120)
  assert delay.resolve("2h", now:) == Ok(8200)
  assert delay.resolve("2d", now:) == Ok(173_800)
}

pub fn duration_normalisation_trims_and_lowercases_before_parsing_test() {
  assert delay.resolve("  2 HOURS  ", now: 1000) == Ok(8200)
  assert delay.resolve("not-a-number seconds", now: 1000)
    == Error(delay.InvalidDelay)
}
