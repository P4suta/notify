import gleam/list
import gleam/option.{type Option, None, Some}
import notify/core/message.{type Message, type Priority}

pub type Criteria {
  Criteria(
    id: Option(String),
    message: Option(String),
    title: Option(String),
    priorities: List(Priority),
    tags: List(String),
  )
}

pub fn none() -> Criteria {
  Criteria(id: None, message: None, title: None, priorities: [], tags: [])
}

pub fn matches(message: Message, criteria: Criteria) -> Bool {
  matches_optional(message.id, criteria.id)
  && matches_optional(message.message, criteria.message)
  && matches_nested_optional(message.title, criteria.title)
  && matches_any(message.priority, criteria.priorities)
  && list.all(criteria.tags, fn(tag) { list.contains(message.tags, tag) })
}

fn matches_any(value: a, expected: List(a)) -> Bool {
  case expected {
    [] -> True
    values -> list.contains(values, value)
  }
}

fn matches_optional(value: a, expected: Option(a)) -> Bool {
  case expected {
    None -> True
    Some(expected) -> value == expected
  }
}

fn matches_nested_optional(value: Option(a), expected: Option(a)) -> Bool {
  case expected {
    None -> True
    Some(expected) -> value == Some(expected)
  }
}
