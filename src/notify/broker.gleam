import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/core/filter
import notify/core/message.{type Message as Notification}
import notify/core/message_json
import notify/core/topic.{type Topic}

pub type Representation {
  Structured
  Raw
}

/// A notification and the immutable representation selected for one
/// subscriber. The broker computes each representation at most once per live
/// fan-out and shares the resulting binary with every matching subscriber.
pub type PreparedMessage {
  PreparedMessage(message: Notification, payload: BitArray)
}

pub type Delivery {
  Open(id: String, time: Int, topics: List(Topic))
  Replay(PreparedMessage)
  Message(PreparedMessage)
  Keepalive(id: String, time: Int, topics: List(Topic))
  Overflow
}

pub type Broker {
  Broker(
    subscribe: fn(List(Topic), Subject(Delivery), Int) -> Int,
    subscribe_filtered: fn(List(Topic), filter.Criteria, Subject(Delivery), Int) ->
      Int,
    subscribe_paused: fn(List(Topic), Subject(Delivery), Int) -> Int,
    subscribe_paused_filtered: fn(
      List(Topic),
      filter.Criteria,
      Subject(Delivery),
      Int,
    ) -> Int,
    subscribe_paused_filtered_as: fn(
      List(Topic),
      filter.Criteria,
      Representation,
      Subject(Delivery),
      Int,
    ) -> Int,
    activate: fn(Int, List(String), Int) -> Nil,
    activate_prepared: fn(Int, Subject(Delivery), Delivery, List(Notification)) ->
      Nil,
    ack: fn(Int) -> Nil,
    unsubscribe: fn(Int) -> Nil,
    broadcast: fn(Notification) -> Nil,
    dispatch: fn(Notification) -> Nil,
    stats: fn() -> Stats,
  )
}

pub type Stats {
  Stats(subscriber_count: Int, topic_count: Int, last_broadcast_candidates: Int)
}

type Subscriber {
  Subscriber(
    id: Int,
    topics: List(Topic),
    subject: Subject(Delivery),
    credit: Int,
    max_credit: Int,
    active: Bool,
    criteria: filter.Criteria,
    representation: Representation,
    pending: List(PreparedMessage),
    pending_count: Int,
    overflowed: Bool,
  )
}

type PreparedRepresentations {
  PreparedRepresentations(structured: Option(BitArray), raw: Option(BitArray))
}

type State {
  State(
    next_id: Int,
    subscribers: Dict(Int, Subscriber),
    topics: Dict(String, List(Int)),
    last_broadcast_candidates: Int,
  )
}

type Command {
  Subscribe(
    List(Topic),
    filter.Criteria,
    Representation,
    Subject(Delivery),
    Int,
    Subject(Int),
  )
  SubscribePaused(
    List(Topic),
    filter.Criteria,
    Representation,
    Subject(Delivery),
    Int,
    Subject(Int),
  )
  Activate(Int, List(String), Int, Subject(Nil))
  ActivatePrepared(
    Int,
    Subject(Delivery),
    Delivery,
    List(Notification),
    Subject(Nil),
  )
  Ack(Int)
  Unsubscribe(Int)
  Broadcast(Notification)
  Dispatch(Notification, Subject(Nil))
  Inspect(Subject(Stats))
}

pub fn start() -> Result(Broker, actor.StartError) {
  use started <- result.try(
    actor.new(State(
      next_id: 1,
      subscribers: dict.new(),
      topics: dict.new(),
      last_broadcast_candidates: 0,
    ))
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    Broker(
      subscribe: fn(topics, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          Subscribe(
            topics,
            filter.none(),
            Structured,
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      subscribe_filtered: fn(topics, criteria, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          Subscribe(
            topics,
            criteria,
            Structured,
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      subscribe_paused: fn(topics, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          SubscribePaused(
            topics,
            filter.none(),
            Structured,
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      subscribe_paused_filtered: fn(topics, criteria, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          SubscribePaused(
            topics,
            criteria,
            Structured,
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      subscribe_paused_filtered_as: fn(
        topics,
        criteria,
        representation,
        subscriber,
        capacity,
      ) {
        process.call(subject, 5000, fn(reply) {
          SubscribePaused(
            topics,
            criteria,
            representation,
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      activate: fn(id, replay_ids, replay_count) {
        process.call(subject, 5000, fn(reply) {
          Activate(id, replay_ids, max(0, replay_count), reply)
        })
      },
      activate_prepared: fn(id, stream, opening, replay) {
        process.call(subject, 5000, fn(reply) {
          ActivatePrepared(id, stream, opening, replay, reply)
        })
      },
      ack: fn(id) { process.send(subject, Ack(id)) },
      unsubscribe: fn(id) { process.send(subject, Unsubscribe(id)) },
      broadcast: fn(message) { process.send(subject, Broadcast(message)) },
      dispatch: fn(message) {
        process.call(subject, 5000, fn(reply) { Dispatch(message, reply) })
      },
      stats: fn() { process.call(subject, 5000, Inspect) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Subscribe(topics, criteria, representation, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics: unique_topics(topics),
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: True,
          criteria:,
          representation:,
          pending: [],
          pending_count: 0,
          overflowed: False,
        )
      process.send(reply, state.next_id)
      actor.continue(add_subscriber(
        State(..state, next_id: state.next_id + 1),
        subscriber,
      ))
    }
    SubscribePaused(topics, criteria, representation, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics: unique_topics(topics),
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: False,
          criteria:,
          representation:,
          pending: [],
          pending_count: 0,
          overflowed: False,
        )
      process.send(reply, state.next_id)
      actor.continue(add_subscriber(
        State(..state, next_id: state.next_id + 1),
        subscriber,
      ))
    }
    Activate(id, replay_ids, replay_count, reply) -> {
      let updated = activate_subscriber(state, id, replay_ids, replay_count)
      process.send(reply, Nil)
      actor.continue(updated)
    }
    ActivatePrepared(id, stream, opening, replay, reply) -> {
      let updated =
        activate_prepared_subscriber(state, id, stream, opening, replay)
      process.send(reply, Nil)
      actor.continue(updated)
    }
    Ack(id) -> actor.continue(ack_subscriber(state, id))
    Unsubscribe(id) -> actor.continue(remove_subscriber(state, id))
    Broadcast(message) -> actor.continue(deliver_message(state, message))
    Dispatch(message, reply) -> {
      let updated = deliver_message(state, message)
      process.send(reply, Nil)
      actor.continue(updated)
    }
    Inspect(reply) -> {
      process.send(
        reply,
        Stats(
          subscriber_count: dict.size(state.subscribers),
          topic_count: dict.size(state.topics),
          last_broadcast_candidates: state.last_broadcast_candidates,
        ),
      )
      actor.continue(state)
    }
  }
}

fn deliver_message(state: State, message: Notification) -> State {
  let candidates =
    dict.get(state.topics, topic.to_string(message.topic))
    |> result.unwrap([])
  deliver_candidates(
    candidates,
    message,
    State(..state, last_broadcast_candidates: list.length(candidates)),
  )
}

fn unique_topics(topics: List(Topic)) -> List(Topic) {
  unique_topics_loop(topics, [])
}

fn unique_topics_loop(topics: List(Topic), unique: List(Topic)) -> List(Topic) {
  case topics {
    [] -> list.reverse(unique)
    [topic, ..rest] ->
      case list.contains(unique, topic) {
        True -> unique_topics_loop(rest, unique)
        False -> unique_topics_loop(rest, [topic, ..unique])
      }
  }
}

fn add_subscriber(state: State, subscriber: Subscriber) -> State {
  State(
    ..state,
    subscribers: dict.insert(state.subscribers, subscriber.id, subscriber),
    topics: register_topics(state.topics, subscriber.topics, subscriber.id),
  )
}

fn register_topics(
  registry: Dict(String, List(Int)),
  topics: List(Topic),
  id: Int,
) -> Dict(String, List(Int)) {
  case topics {
    [] -> registry
    [current_topic, ..rest] -> {
      let key = topic.to_string(current_topic)
      let subscribers = dict.get(registry, key) |> result.unwrap([])
      register_topics(dict.insert(registry, key, [id, ..subscribers]), rest, id)
    }
  }
}

fn remove_subscriber(state: State, id: Int) -> State {
  case dict.get(state.subscribers, id) {
    Error(_) -> state
    Ok(subscriber) ->
      State(
        ..state,
        subscribers: dict.delete(state.subscribers, id),
        topics: unregister_topics(state.topics, subscriber.topics, id),
      )
  }
}

fn unregister_topics(
  registry: Dict(String, List(Int)),
  topics: List(Topic),
  id: Int,
) -> Dict(String, List(Int)) {
  case topics {
    [] -> registry
    [current_topic, ..rest] -> {
      let key = topic.to_string(current_topic)
      let remaining =
        dict.get(registry, key)
        |> result.unwrap([])
        |> list.filter(fn(candidate) { candidate != id })
      let updated = case remaining {
        [] -> dict.delete(registry, key)
        _ -> dict.insert(registry, key, remaining)
      }
      unregister_topics(updated, rest, id)
    }
  }
}

fn ack_subscriber(state: State, id: Int) -> State {
  case dict.get(state.subscribers, id) {
    Error(_) -> state
    Ok(subscriber) ->
      put_subscriber(
        state,
        Subscriber(
          ..subscriber,
          credit: min(subscriber.credit + 1, subscriber.max_credit),
        ),
      )
  }
}

fn put_subscriber(state: State, subscriber: Subscriber) -> State {
  State(
    ..state,
    subscribers: dict.insert(state.subscribers, subscriber.id, subscriber),
  )
}

fn deliver_candidates(
  candidates: List(Int),
  message: Notification,
  state: State,
) -> State {
  let #(state, _) =
    deliver_candidates_loop(
      candidates,
      message,
      state,
      PreparedRepresentations(None, None),
    )
  state
}

fn deliver_candidates_loop(
  candidates: List(Int),
  message: Notification,
  state: State,
  prepared: PreparedRepresentations,
) -> #(State, PreparedRepresentations) {
  case candidates {
    [] -> #(state, prepared)
    [id, ..rest] ->
      case dict.get(state.subscribers, id) {
        Error(_) -> deliver_candidates_loop(rest, message, state, prepared)
        Ok(subscriber) ->
          case filter.matches(message, subscriber.criteria), subscriber.active {
            False, _ -> deliver_candidates_loop(rest, message, state, prepared)
            True, False if subscriber.pending_count >= subscriber.max_credit ->
              deliver_candidates_loop(
                rest,
                message,
                put_subscriber(
                  state,
                  Subscriber(..subscriber, overflowed: True),
                ),
                prepared,
              )
            True, False -> {
              let #(payload, prepared) =
                prepare_cached(message, subscriber.representation, prepared)
              deliver_candidates_loop(
                rest,
                message,
                put_subscriber(
                  state,
                  Subscriber(
                    ..subscriber,
                    pending: [payload, ..subscriber.pending],
                    pending_count: subscriber.pending_count + 1,
                  ),
                ),
                prepared,
              )
            }
            True, True if subscriber.credit > 0 -> {
              let #(payload, prepared) =
                prepare_cached(message, subscriber.representation, prepared)
              process.send(subscriber.subject, Message(payload))
              deliver_candidates_loop(
                rest,
                message,
                put_subscriber(
                  state,
                  Subscriber(..subscriber, credit: subscriber.credit - 1),
                ),
                prepared,
              )
            }
            True, True -> {
              process.send(subscriber.subject, Overflow)
              deliver_candidates_loop(
                rest,
                message,
                remove_subscriber(state, id),
                prepared,
              )
            }
          }
      }
  }
}

fn activate_subscriber(
  state: State,
  id: Int,
  replay_ids: List(String),
  replay_count: Int,
) -> State {
  case dict.get(state.subscribers, id) {
    Error(_) -> state
    Ok(subscriber) -> {
      let pending =
        subscriber.pending
        |> list.reverse
        |> list.filter(fn(prepared) {
          !list.contains(replay_ids, prepared.message.id)
        })
      let credit = max(0, subscriber.max_credit - replay_count)
      case subscriber.overflowed || list.length(pending) > credit {
        True -> {
          process.send(subscriber.subject, Overflow)
          remove_subscriber(state, id)
        }
        False -> {
          list.each(pending, fn(message) {
            process.send(subscriber.subject, Message(message))
          })
          put_subscriber(
            state,
            Subscriber(
              ..subscriber,
              active: True,
              pending: [],
              pending_count: 0,
              credit: credit - list.length(pending),
            ),
          )
        }
      }
    }
  }
}

fn activate_prepared_subscriber(
  state: State,
  id: Int,
  stream: Subject(Delivery),
  opening: Delivery,
  replay: List(Notification),
) -> State {
  case dict.get(state.subscribers, id) {
    Error(_) -> state
    Ok(subscriber) -> {
      process.send(stream, opening)
      let replay_count = list.length(replay)
      let replay_to_send = list.take(replay, subscriber.max_credit)
      let prepared_replay =
        prepare_many(replay_to_send, subscriber.representation, [])
      list.each(prepared_replay, fn(prepared) {
        process.send(stream, Replay(prepared))
      })
      let replay_ids = list.map(replay, fn(message) { message.id })
      let pending =
        subscriber.pending
        |> list.reverse
        |> list.filter(fn(prepared) {
          !list.contains(replay_ids, prepared.message.id)
        })
      let credit = max(0, subscriber.max_credit - replay_count)
      case
        replay_count > subscriber.max_credit
        || subscriber.overflowed
        || list.length(pending) > credit
      {
        True -> {
          process.send(stream, Overflow)
          remove_subscriber(state, id)
        }
        False -> {
          list.each(pending, fn(message) {
            process.send(stream, Message(message))
          })
          put_subscriber(
            state,
            Subscriber(
              ..subscriber,
              subject: stream,
              active: True,
              pending: [],
              pending_count: 0,
              credit: credit - list.length(pending),
            ),
          )
        }
      }
    }
  }
}

fn prepare_many(
  messages: List(Notification),
  representation: Representation,
  accumulated: List(PreparedMessage),
) -> List(PreparedMessage) {
  case messages {
    [] -> list.reverse(accumulated)
    [message, ..remaining] ->
      prepare_many(remaining, representation, [
        prepare_message(message, representation),
        ..accumulated
      ])
  }
}

fn prepare_cached(
  message: Notification,
  representation: Representation,
  cached: PreparedRepresentations,
) -> #(PreparedMessage, PreparedRepresentations) {
  case representation, cached {
    Structured, PreparedRepresentations(structured: Some(payload), ..) -> #(
      PreparedMessage(message, payload),
      cached,
    )
    Raw, PreparedRepresentations(raw: Some(payload), ..) -> #(
      PreparedMessage(message, payload),
      cached,
    )
    Structured, _ -> {
      let payload = structured_payload(message)
      #(
        PreparedMessage(message, payload),
        PreparedRepresentations(..cached, structured: Some(payload)),
      )
    }
    Raw, _ -> {
      let payload = raw_payload(message)
      #(
        PreparedMessage(message, payload),
        PreparedRepresentations(..cached, raw: Some(payload)),
      )
    }
  }
}

/// Prepare a message outside a fan-out, primarily for replay producers and
/// deterministic transport tests.
pub fn prepare_message(
  message: Notification,
  representation: Representation,
) -> PreparedMessage {
  let #(prepared, _) =
    prepare_cached(message, representation, PreparedRepresentations(None, None))
  prepared
}

fn structured_payload(message: Notification) -> BitArray {
  message |> message_json.encode |> json.to_string |> bit_array.from_string
}

fn raw_payload(message: Notification) -> BitArray {
  message.message
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> fn(value) { value <> "\n" }
  |> bit_array.from_string
}

fn min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
