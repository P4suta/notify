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
    ack: fn(Int) -> Nil,
    unsubscribe: fn(Int) -> Nil,
    broadcast: fn(Notification) -> Nil,
  )
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
  State(next_id: Int, subscribers: List(Subscriber))
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
  Ack(Int)
  Unsubscribe(Int)
  Broadcast(Notification)
}

pub fn start() -> Result(Broker, actor.StartError) {
  use started <- result.try(
    actor.new(State(next_id: 1, subscribers: []))
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
      ack: fn(id) { process.send(subject, Ack(id)) },
      unsubscribe: fn(id) { process.send(subject, Unsubscribe(id)) },
      broadcast: fn(message) { process.send(subject, Broadcast(message)) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Subscribe(topics, criteria, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics:,
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: True,
          criteria:,
          pending: [],
          overflowed: False,
        )
      process.send(reply, state.next_id)
      actor.continue(
        State(next_id: state.next_id + 1, subscribers: [
          subscriber,
          ..state.subscribers
        ]),
      )
    }
    SubscribePaused(topics, criteria, subject, capacity, reply) -> {
      let subscriber =
        Subscriber(
          id: state.next_id,
          topics:,
          subject:,
          credit: capacity,
          max_credit: capacity,
          active: False,
          criteria:,
          pending: [],
          overflowed: False,
        )
      process.send(reply, state.next_id)
      actor.continue(
        State(next_id: state.next_id + 1, subscribers: [
          subscriber,
          ..state.subscribers
        ]),
      )
    }
    Activate(id, replay_ids, replay_count, reply) -> {
      let updated =
        activate_subscriber(state.subscribers, id, replay_ids, replay_count, [])
      process.send(reply, Nil)
      actor.continue(State(..state, subscribers: updated))
    }
    Ack(id) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.map(state.subscribers, fn(subscriber) {
            case subscriber.id == id {
              False -> subscriber
              True ->
                Subscriber(
                  ..subscriber,
                  credit: min(subscriber.credit + 1, subscriber.max_credit),
                )
            }
          }),
        ),
      )
    Unsubscribe(id) ->
      actor.continue(
        State(
          ..state,
          subscribers: list.filter(state.subscribers, fn(subscriber) {
            subscriber.id != id
          }),
        ),
      )
    Broadcast(message) ->
      actor.continue(
        State(..state, subscribers: deliver(state.subscribers, message, [])),
      )
  }
}

fn deliver(
  subscribers: List(Subscriber),
  message: Notification,
  retained: List(Subscriber),
) -> List(Subscriber) {
  case subscribers {
    [] -> list.reverse(retained)
    [subscriber, ..rest] ->
      case
        list.contains(subscriber.topics, message.topic)
        && filter.matches(message, subscriber.criteria),
        subscriber.active
      {
        False, _ -> deliver(rest, message, [subscriber, ..retained])
        True, False -> {
          let buffered = list.append(subscriber.pending, [message])
          let overflowed =
            subscriber.overflowed
            || list.length(buffered) > subscriber.max_credit
          deliver(rest, message, [
            Subscriber(
              ..subscriber,
              pending: list.take(buffered, subscriber.max_credit),
              overflowed:,
            ),
            ..retained
          ])
        }
        True, True if subscriber.credit > 0 -> {
          process.send(subscriber.subject, Message(message))
          deliver(rest, message, [
            Subscriber(..subscriber, credit: subscriber.credit - 1),
            ..retained
          ])
        }
        True, True -> {
          process.send(subscriber.subject, Overflow)
          deliver(rest, message, retained)
        }
      }
  }
}

fn activate_subscriber(
  subscribers: List(Subscriber),
  id: Int,
  replay_ids: List(String),
  replay_count: Int,
  retained: List(Subscriber),
) -> List(Subscriber) {
  case subscribers {
    [] -> list.reverse(retained)
    [subscriber, ..rest] ->
      case subscriber.id == id {
        False ->
          activate_subscriber(rest, id, replay_ids, replay_count, [
            subscriber,
            ..retained
          ])
        True -> {
          let pending =
            list.filter(subscriber.pending, fn(message) {
              !list.contains(replay_ids, message.id)
            })
          let credit = max(0, subscriber.max_credit - replay_count)
          case subscriber.overflowed || list.length(pending) > credit {
            True -> {
              process.send(subscriber.subject, Overflow)
              list.append(list.reverse(retained), rest)
            }
            False -> {
              list.each(pending, fn(message) {
                process.send(subscriber.subject, Message(message))
              })
              let activated =
                Subscriber(
                  ..subscriber,
                  active: True,
                  pending: [],
                  credit: credit - list.length(pending),
                )
              list.append(list.reverse([activated, ..retained]), rest)
            }
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
