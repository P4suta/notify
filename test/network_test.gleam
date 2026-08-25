import notify/network

pub fn outbound_tcp_clients_disable_nagle_for_database_round_trips_test() {
  network.configure_tcp_clients()

  assert network.tcp_nodelay_enabled()
}
