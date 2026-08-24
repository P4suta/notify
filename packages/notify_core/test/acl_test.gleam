import notify/core/acl

pub fn admin_can_read_and_write_every_topic_test() {
  let admin = acl.Authenticated("root", acl.Admin)
  assert acl.authorize(admin, "secret", acl.Read, [], acl.Deny)
  assert acl.authorize(admin, "secret", acl.Write, [], acl.Deny)
}

pub fn wildcard_matches_zero_or_more_characters_case_sensitively_test() {
  assert acl.pattern_matches("", "")
  assert !acl.pattern_matches("", "anything")
  assert acl.pattern_matches("alerts-*", "alerts-")
  assert acl.pattern_matches("alerts-*", "alerts-disk-full")
  assert !acl.pattern_matches("alerts-*", "Alerts-disk-full")
  assert acl.pattern_matches("*", "anything")
}

pub fn anonymous_principals_never_inherit_named_user_rules_test() {
  let rules = [
    acl.Rule("pat", "*", acl.ReadWrite),
    acl.Rule("*", "public-*", acl.ReadOnly),
  ]
  assert !acl.authorize(acl.Anonymous, "private", acl.Read, rules, acl.Deny)
  assert acl.authorize(acl.Anonymous, "public-news", acl.Read, rules, acl.Deny)
}

pub fn specific_user_rule_beats_everyone_even_when_shorter_test() {
  let rules = [
    acl.Rule("*", "private-reports-*", acl.ReadWrite),
    acl.Rule("pat", "*", acl.Deny),
  ]
  let pat = acl.Authenticated("pat", acl.User)
  assert !acl.authorize(pat, "private-reports-q1", acl.Read, rules, acl.Deny)
  assert acl.authorize(
    acl.Anonymous,
    "private-reports-q1",
    acl.Read,
    rules,
    acl.Deny,
  )
}

pub fn longer_matching_pattern_beats_general_rule_test() {
  let rules = [
    acl.Rule("pat", "*", acl.ReadWrite),
    acl.Rule("pat", "secret-*", acl.Deny),
  ]
  let pat = acl.Authenticated("pat", acl.User)
  assert acl.authorize(pat, "public", acl.Write, rules, acl.Deny)
  assert !acl.authorize(pat, "secret-payroll", acl.Read, rules, acl.Deny)
}

pub fn equal_length_write_rule_wins_to_match_ntfy_precedence_test() {
  let rules = [
    acl.Rule("pat", "jobs-*", acl.ReadOnly),
    acl.Rule("pat", "*-done", acl.WriteOnly),
  ]
  let pat = acl.Authenticated("pat", acl.User)
  assert acl.authorize(pat, "jobs-done", acl.Write, rules, acl.Deny)
  assert !acl.authorize(pat, "jobs-done", acl.Read, rules, acl.Deny)
}

pub fn precedence_is_independent_of_rule_order_test() {
  let pat = acl.Authenticated("pat", acl.User)
  let specific_first = [
    acl.Rule("pat", "*", acl.Deny),
    acl.Rule("*", "private-reports-*", acl.ReadWrite),
  ]
  assert !acl.authorize(
    pat,
    "private-reports-q1",
    acl.Read,
    specific_first,
    acl.Deny,
  )

  let longer_first = [
    acl.Rule("pat", "secret-*", acl.Deny),
    acl.Rule("pat", "*", acl.ReadWrite),
  ]
  assert !acl.authorize(pat, "secret-payroll", acl.Read, longer_first, acl.Deny)
}

pub fn equal_length_non_write_rule_does_not_replace_existing_deny_test() {
  let rules = [
    acl.Rule("pat", "jobs-*", acl.Deny),
    acl.Rule("pat", "*-done", acl.ReadOnly),
  ]
  let pat = acl.Authenticated("pat", acl.User)
  assert !acl.authorize(pat, "jobs-done", acl.Read, rules, acl.ReadWrite)
}

pub fn permission_matrix_is_explicit_test() {
  assert !acl.allows(acl.Deny, acl.Read)
  assert !acl.allows(acl.Deny, acl.Write)
  assert acl.allows(acl.ReadOnly, acl.Read)
  assert !acl.allows(acl.ReadOnly, acl.Write)
  assert !acl.allows(acl.WriteOnly, acl.Read)
  assert acl.allows(acl.WriteOnly, acl.Write)
  assert acl.allows(acl.ReadWrite, acl.Read)
  assert acl.allows(acl.ReadWrite, acl.Write)
}

pub fn fallback_applies_only_when_no_rule_matches_test() {
  assert acl.authorize(acl.Anonymous, "public", acl.Read, [], acl.ReadOnly)
  assert !acl.authorize(acl.Anonymous, "public", acl.Write, [], acl.ReadOnly)
}
