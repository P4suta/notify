import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import notify/core/filter
import notify/core/message.{type Message as Notification}
import notify/core/topic.{type Topic}

pub type Delivery {
  Open(id: String, time: Int, topics: List(Topic))
  Replay(Notification)
  Message(Notification)
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
    pending: List(Notification),
    overflowed: Bool,
  )
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
  Subscribe(List(Topic), filter.Criteria, Subject(Delivery), Int, Subject(Int))
  SubscribePaused(
    List(Topic),
    filter.Criteria,
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
          Subscribe(topics, filter.none(), subscriber, max(1, capacity), reply)
        })
      },
      subscribe_filtered: fn(topics, criteria, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          Subscribe(topics, criteria, subscriber, max(1, capacity), reply)
        })
      },
      subscribe_paused: fn(topics, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          SubscribePaused(
            topics,
            filter.none(),
            subscriber,
            max(1, capacity),
            reply,
          )
        })
      },
      subscribe_paused_filtered: fn(topics, criteria, subscriber, capacity) {
        process.call(subject, 5000, fn(reply) {
          SubscribePaused(topics, criteria, subscriber, max(1, capacity), reply)
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
    Subscribe(topics, criteria, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics: unique_topics(topics),
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: True,
          criteria:,
          pending: [],
          overflowed: False,
        )
      process.send(reply, state.next_id)
      actor.continue(add_subscriber(
        State(..state, next_id: state.next_id + 1),
        subscriber,
      ))
    }
    SubscribePaused(topics, criteria, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics: unique_topics(topics),
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: False,
          criteria:,
          pending: [],
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
  case candidates {
    [] -> state
    [id, ..rest] ->
      case dict.get(state.subscribers, id) {
        Error(_) -> deliver_candidates(rest, message, state)
        Ok(subscriber) ->
          case filter.matches(message, subscriber.criteria), subscriber.active {
            False, _ -> deliver_candidates(rest, message, state)
            True, False -> {
              let buffered = list.append(subscriber.pending, [message])
              let overflowed =
                subscriber.overflowed
                || list.length(buffered) > subscriber.max_credit
              deliver_candidates(
                rest,
                message,
                put_subscriber(
                  state,
                  Subscriber(
                    ..subscriber,
                    pending: list.take(buffered, subscriber.max_credit),
                    overflowed:,
                  ),
                ),
              )
            }
            True, True if subscriber.credit > 0 -> {
              process.send(subscriber.subject, Message(message))
              deliver_candidates(
                rest,
                message,
                put_subscriber(
                  state,
                  Subscriber(..subscriber, credit: subscriber.credit - 1),
                ),
              )
            }
            True, True -> {
              process.send(subscriber.subject, Overflow)
              deliver_candidates(rest, message, remove_subscriber(state, id))
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
        list.filter(subscriber.pending, fn(message) {
          !list.contains(replay_ids, message.id)
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
      replay
      |> list.take(subscriber.max_credit)
      |> list.each(fn(message) { process.send(stream, Replay(message)) })
      let replay_ids = list.map(replay, fn(message) { message.id })
      let pending =
        list.filter(subscriber.pending, fn(message) {
          !list.contains(replay_ids, message.id)
        })
      let credit = max(0, subscriber.max_credit - list.length(replay))
      case
        list.length(replay) > subscriber.max_credit
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
              credit: credit - list.length(pending),
            ),
          )
        }
      }
    }
  }
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
