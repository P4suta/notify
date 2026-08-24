import gleam/option.{None, Some}
import notify/proxy

pub fn forwarded_addresses_are_used_only_for_explicitly_trusted_peers_test() {
  assert proxy.client_ip(
      "10.0.0.10",
      ["10.0.0.10"],
      Some("198.51.100.20, 10.0.0.11"),
      None,
    )
    == "198.51.100.20"
  assert proxy.client_ip(
      "203.0.113.5",
      ["10.0.0.10"],
      Some("198.51.100.20"),
      None,
    )
    == "203.0.113.5"
}

pub fn rfc_forwarded_for_and_malformed_values_are_handled_safely_test() {
  assert proxy.client_ip(
      "127.0.0.1",
      ["127.0.0.1"],
      None,
      Some("for=\"[2001:db8::1]\";proto=https"),
    )
    == "2001:db8::1"
  assert proxy.client_ip(
      "127.0.0.1",
      ["127.0.0.1"],
      Some("bad value / injected"),
      None,
    )
    == "127.0.0.1"
}
