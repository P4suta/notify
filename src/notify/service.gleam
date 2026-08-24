import gleam/bit_array
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/delay
import notify/core/message.{type Draft, type Message}
import notify/core/message_json
import notify/core/topic as notify_topic
import notify/delivery
import notify/runtime.{type Runtime}
import notify/security/token
import notify/storage
import notify/webpush

pub type Error {
  InvalidMessage(message.ValidationError)
  InvalidDelay(delay.Error)
  Persistence(storage.Error)
  Delivery(delivery.Error)
  WebPush(webpush.Error)
}

const unique_id_attempts = 8

pub fn publish(draft: Draft, runtime: Runtime) -> Result(Message, Error) {
  let runtime.Clock(now) = runtime.clock
  let timestamp = now()
  use scheduled_for <- result.try(
    resolve_schedule(draft.delay, timestamp) |> result.map_error(InvalidDelay),
  )
  publish_attempt(draft, runtime, timestamp, scheduled_for, unique_id_attempts)
}

fn publish_attempt(
  draft: Draft,
  runtime: Runtime,
  timestamp: Int,
  scheduled_for: Option(Int),
  attempts_remaining: Int,
) -> Result(Message, Error) {
  let runtime.IdGenerator(next_id) = runtime.ids
  use candidate <- result.try(
    message.materialise(
      draft,
      id: next_id(),
      now: timestamp,
      expires: timestamp + runtime.retention_seconds,
    )
    |> result.map_error(InvalidMessage),
  )
  let candidate = case scheduled_for {
    None -> candidate
    Some(due_at) ->
      message.Message(
        ..candidate,
        time: due_at,
        expires: option.map(candidate.expires, fn(_) {
          due_at + runtime.retention_seconds
        }),
        scheduled: True,
      )
  }
  case commit_and_maybe_broadcast(candidate, runtime) {
    Error(Persistence(storage.Conflict(_))) if attempts_remaining > 1 ->
      publish_attempt(
        draft,
        runtime,
        timestamp,
        scheduled_for,
        attempts_remaining - 1,
      )
    outcome -> outcome
  }
}

pub fn publish_control(
  topic topic: notify_topic.Topic,
  event event: message.Event,
  sequence_id sequence_id: String,
  runtime runtime: Runtime,
) -> Result(Message, Error) {
  let runtime.Clock(now) = runtime.clock
  let timestamp = now()
  publish_control_attempt(
    topic,
    event,
    sequence_id,
    runtime,
    timestamp,
    unique_id_attempts,
  )
}

fn publish_control_attempt(
  topic: notify_topic.Topic,
  event: message.Event,
  sequence_id: String,
  runtime: Runtime,
  timestamp: Int,
  attempts_remaining: Int,
) -> Result(Message, Error) {
  let runtime.IdGenerator(next_id) = runtime.ids
  use candidate <- result.try(
    message.materialise_control(
      topic:,
      event:,
      sequence_id:,
      id: next_id(),
      now: timestamp,
    )
    |> result.map_error(InvalidMessage),
  )
  let outcome =
    commit_and_maybe_broadcast(
      message.Message(
        ..candidate,
        expires: Some(timestamp + runtime.retention_seconds),
      ),
      runtime,
    )
  case outcome {
    Error(Persistence(storage.Conflict(_))) if attempts_remaining > 1 ->
      publish_control_attempt(
        topic,
        event,
        sequence_id,
        runtime,
        timestamp,
        attempts_remaining - 1,
      )
    outcome -> outcome
  }
}

pub fn release_due(runtime: Runtime, limit: Int) -> Result(Int, Error) {
  let runtime.Clock(now) = runtime.clock
  use messages <- result.try(
    runtime.storage.release_due(now(), limit) |> result.map_error(Persistence),
  )
  list.each(messages, runtime.broadcast)
  Ok(list.length(messages))
}

fn resolve_schedule(
  value: Option(String),
  now: Int,
) -> Result(Option(Int), delay.Error) {
  case value {
    None -> Ok(None)
    Some(value) -> delay.resolve(value, now:) |> result.map(Some)
  }
}

fn commit_and_maybe_broadcast(
  candidate: Message,
  runtime: Runtime,
) -> Result(Message, Error) {
  use jobs <- result.try(delivery_jobs(candidate, runtime))
  let runtime.Committer(commit) = runtime.committer
  use committed <- result.try(
    commit(candidate, jobs)
    |> result.map_error(fn(error) {
      case error {
        runtime.CommitPersistence(error) -> Persistence(error)
        runtime.CommitDelivery(error) -> Delivery(error)
      }
    }),
  )
  case committed.scheduled {
    True -> Ok(committed)
    False -> {
      runtime.broadcast(committed)
      Ok(committed)
    }
  }
}

fn webpush_jobs(
  message: Message,
  runtime: Runtime,
) -> Result(List(delivery.NewJob), Error) {
  case runtime.webpush, runtime.deliveries {
    Some(configured), Some(_) -> {
      let topic_name = notify_topic.to_string(message.topic)
      let topic_url = join_url(runtime.attachment_base_url, topic_name)
      use subscriptions <- result.try(
        configured.store.for_topic(topic_name) |> result.map_error(WebPush),
      )
      let payload =
        json.object([
          #("event", json.string("message")),
          #("subscription_id", json.string(topic_url)),
          #("message", message_json.encode(message)),
        ])
        |> json.to_string
        |> bit_array.from_string
      Ok(
        subscriptions
        |> list.map(fn(subscription) {
          delivery.NewJob(
            id: "wp_" <> message.id <> "_" <> subscription.id,
            kind: delivery.WebPush,
            endpoint: subscription.endpoint,
            payload:,
            message_id: message.id,
            topic_hash: token.digest(topic_url),
            available_at: message.time,
          )
        }),
      )
    }
    _, _ -> Ok([])
  }
}

fn delivery_jobs(
  message: Message,
  runtime: Runtime,
) -> Result(List(delivery.NewJob), Error) {
  use webpush <- result.try(webpush_jobs(message, runtime))
  Ok(list.append(webpush, relay_jobs(message, runtime)))
}

fn relay_jobs(message: Message, runtime: Runtime) -> List(delivery.NewJob) {
  case runtime.relay, runtime.deliveries {
    Some(configured), Some(_) -> {
      let topic_url =
        join_url(
          runtime.attachment_base_url,
          notify_topic.to_string(message.topic),
        )
      let topic_hash = token.digest(topic_url)
      [
        delivery.NewJob(
          id: "relay_" <> message.id,
          kind: delivery.MobileRelay,
          endpoint: join_url(configured.base_url, topic_hash),
          payload: <<>>,
          message_id: message.id,
          topic_hash:,
          available_at: message.time,
        ),
      ]
    }
    _, _ -> []
  }
}

fn join_url(base: String, path: String) -> String {
  case string.is_empty(base), string.ends_with(base, "/") {
    True, _ -> "/" <> path
    False, True -> base <> path
    False, False -> base <> "/" <> path
  }
}
