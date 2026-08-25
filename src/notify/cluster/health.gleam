import gleam/option.{type Option}

pub const stale_after_seconds = 604_800

pub type Node {
  Node(node_id: String, sequence: Int, updated_at: Int, stale: Bool)
}

pub type Page {
  Page(items: List(Node), has_more: Bool)
}

pub type Snapshot {
  Snapshot(
    local_node_id: String,
    event_head: Int,
    database_time: Int,
    cursor_count: Int,
    stale_nodes: Int,
    nodes: Page,
  )
}

pub type Error {
  InvalidPage
  Unavailable(String)
  Corrupt(String)
}

pub type Store {
  Store(inspect: fn(Option(String), Int) -> Result(Snapshot, Error))
}
