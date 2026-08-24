import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import notify/webpush.{type Store, type Subscription}

type State {
  State(subscriptions: List(Subscription), max_endpoints_per_ip: Int)
}

type Command {
  Upsert(webpush.NewSubscription, Subject(Result(Subscription, webpush.Error)))
  ForTopic(String, Subject(Result(List(Subscription), webpush.Error)))
  ByEndpoint(String, Subject(Result(Subscription, webpush.Error)))
  RemoveEndpoint(String, Subject(Result(Nil, webpush.Error)))
  RemoveUser(String, Subject(Result(Int, webpush.Error)))
  RemoveExpired(Int, Subject(Result(Int, webpush.Error)))
  Health(Subject(Result(Nil, webpush.Error)))
}

pub fn start(max_endpoints_per_ip limit: Int) -> Result(Store, webpush.Error) {
  use started <- result.try(
    actor.new(State(subscriptions: [], max_endpoints_per_ip: max(1, limit)))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      webpush.Unavailable("Web Push memory actor failed to start")
    }),
  )
  let subject = started.data
  Ok(store(subject))
}

fn store(subject: Subject(Command)) -> Store {
  webpush.Store(
    upsert: fn(value) {
      process.call(subject, 10_000, fn(reply) { Upsert(value, reply) })
    },
    for_topic: fn(topic) {
      process.call(subject, 10_000, fn(reply) { ForTopic(topic, reply) })
    },
    by_endpoint: fn(endpoint) {
      process.call(subject, 10_000, fn(reply) { ByEndpoint(endpoint, reply) })
    },
    remove_endpoint: fn(endpoint) {
      process.call(subject, 10_000, fn(reply) {
        RemoveEndpoint(endpoint, reply)
      })
    },
    remove_user: fn(user_id) {
      process.call(subject, 10_000, fn(reply) { RemoveUser(user_id, reply) })
    },
    remove_expired: fn(before) {
      process.call(subject, 10_000, fn(reply) { RemoveExpired(before, reply) })
    },
    health: fn() { process.call(subject, 10_000, Health) },
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Upsert(value, reply) -> {
      case upsert(state, value) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(#(updated, subscription)) -> {
          process.send(reply, Ok(subscription))
          actor.continue(updated)
        }
      }
    }
    ForTopic(topic, reply) -> {
      let subscriptions =
        state.subscriptions
        |> list.filter(fn(subscription) {
          list.contains(subscription.topics, topic)
        })
      process.send(reply, Ok(subscriptions))
      actor.continue(state)
    }
    ByEndpoint(endpoint, reply) -> {
      process.send(reply, find_endpoint(state.subscriptions, endpoint))
      actor.continue(state)
    }
    RemoveEndpoint(endpoint, reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        State(
          ..state,
          subscriptions: list.filter(state.subscriptions, fn(subscription) {
            subscription.endpoint != endpoint
          }),
        ),
      )
    }
    RemoveUser(user_id, reply) -> {
      let remaining =
        list.filter(state.subscriptions, fn(subscription) {
          webpush.user_id_string(subscription.user_id) != user_id
        })
      process.send(
        reply,
        Ok(list.length(state.subscriptions) - list.length(remaining)),
      )
      actor.continue(State(..state, subscriptions: remaining))
    }
    RemoveExpired(before, reply) -> {
      let remaining =
        list.filter(state.subscriptions, fn(subscription) {
          subscription.updated_at > before
        })
      process.send(
        reply,
        Ok(list.length(state.subscriptions) - list.length(remaining)),
      )
      actor.continue(State(..state, subscriptions: remaining))
    }
    Health(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }
  }
}

fn upsert(
  state: State,
  value: webpush.NewSubscription,
) -> Result(#(State, Subscription), webpush.Error) {
  use _ <- result.try(webpush.validate(value))
  let existing = find_endpoint(state.subscriptions, value.endpoint)
  case existing {
    Error(webpush.NotFound) -> {
      let ip_count =
        state.subscriptions
        |> list.filter(fn(subscription) {
          subscription.subscriber_ip == value.subscriber_ip
        })
        |> list.length
      case ip_count >= state.max_endpoints_per_ip {
        True -> Error(webpush.TooManySubscriptions)
        False -> {
          let subscription = webpush.from_new(value)
          Ok(#(
            State(
              ..state,
              subscriptions: list.append(state.subscriptions, [subscription]),
            ),
            subscription,
          ))
        }
      }
    }
    Error(error) -> Error(error)
    Ok(previous) -> {
      let candidate = webpush.from_new(value)
      let subscription =
        webpush.Subscription(
          ..candidate,
          id: previous.id,
          created_at: previous.created_at,
        )
      let subscriptions =
        list.map(state.subscriptions, fn(current) {
          case current.endpoint == value.endpoint {
            True -> subscription
            False -> current
          }
        })
      Ok(#(State(..state, subscriptions:), subscription))
    }
  }
}

fn find_endpoint(
  subscriptions: List(Subscription),
  endpoint: String,
) -> Result(Subscription, webpush.Error) {
  subscriptions
  |> list.find(fn(subscription) { subscription.endpoint == endpoint })
  |> result.map_error(fn(_) { webpush.NotFound })
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}
