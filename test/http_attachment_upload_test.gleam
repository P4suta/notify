import gleam/option.{None}
import notify/attachment_store
import notify/attachment_store/memory
import notify/http/attachment_upload
import notify/http/transport

pub fn body_reader_streams_chunks_into_attachment_store_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 32, max_total_bytes: 64)
  let reader = chunk_reader([<<0, 1>>, <<2, 3, 4>>, <<5>>])
  let assert Ok(stored) = attachment_upload.consume(reader, store, 123, 32)
  assert stored.size == 6
  assert stored.expires == 123
  let assert Ok(download) = store.get(stored.key, None)
  assert download.data == <<0, 1, 2, 3, 4, 5>>
}

pub fn body_reader_aborts_partial_upload_over_request_limit_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 32, max_total_bytes: 64)
  let reader = chunk_reader([<<0, 1>>, <<2, 3>>])
  let assert Error(attachment_store.TooLarge(3, 4)) =
    attachment_upload.consume(reader, store, 123, 3)
  let assert Ok(objects) = store.list()
  assert objects == []
}

fn chunk_reader(
  chunks: List(BitArray),
) -> transport.BodyReader(List(BitArray)) {
  transport.body_reader(
    chunks,
    fn(chunks, _maximum_bytes) {
      case chunks {
        [] -> Ok(#(transport.BodyEnd, []))
        [chunk, ..rest] -> Ok(#(transport.BodyChunk(chunk), rest))
      }
    },
    fn(_) { Nil },
  )
}
