import gleam/list
import notify/core/topic

pub fn accepts_ntfy_topic_alphabet_test() {
  let assert Ok(value) = topic.parse("alerts_Prod-42")
  assert topic.to_string(value) == "alerts_Prod-42"
}

pub fn accepts_one_and_sixty_four_char_topics_test() {
  let assert Ok(_) = topic.parse("a")
  let assert Ok(_) =
    topic.parse(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
}

pub fn rejects_empty_long_or_unsafe_topics_test() {
  let assert Error(topic.Empty) = topic.parse("")
  let assert Error(topic.TooLong(65)) =
    topic.parse(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    )
  let assert Error(topic.InvalidCharacter("/")) = topic.parse("ops/prod")
  let assert Error(topic.InvalidCharacter(".")) = topic.parse("ops.prod")
}

pub fn parses_comma_separated_topics_without_duplicates_test() {
  let assert Ok(values) = topic.parse_many("one,two,one")
  assert values |> topic.many_to_strings == ["one", "two"]
}

pub fn reserves_every_pinned_ntfy_http_topic_test() {
  let reserved = [
    "docs",
    "static",
    "file",
    "app",
    "metrics",
    "account",
    "settings",
    "signup",
    "login",
    "v1",
  ]
  let parsed =
    list.map(reserved, fn(name) {
      let assert Ok(value) = topic.parse(name)
      value
    })
  assert list.all(parsed, topic.is_disallowed)
  assert topic.any_disallowed(parsed)

  let assert Ok(allowed) = topic.parse("documentation")
  assert !topic.is_disallowed(allowed)
  assert !topic.any_disallowed([allowed])
}
