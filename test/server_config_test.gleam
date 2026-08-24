import notify/config
import notify/server
import postgleam/config as postgres_config

pub fn maps_notify_postgres_configuration_test() {
  let value =
    config.Config(
      ..config.defaults(),
      postgres_host: "database.internal",
      postgres_port: 5544,
      postgres_database: "notify_test",
      postgres_username: "service",
      postgres_password: "password",
      postgres_ssl: config.SslUnverified,
    )
  let mapped = server.postgres_config(value)
  assert mapped.host == "database.internal"
  assert mapped.port == 5544
  assert mapped.database == "notify_test"
  assert mapped.username == "service"
  assert mapped.password == "password"
  assert mapped.ssl == postgres_config.SslUnverified
}
