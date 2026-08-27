//// Shared bounded attachment upload consumer for HTTP transports.

import gleam/bit_array
import notify/attachment_store
import notify/http/transport

/// Maximum data requested from a transport or written to storage at once.
pub const maximum_chunk_bytes = 1_048_576

/// Consume one request body into the configured attachment store.
///
/// The body and upload handle are explicitly abandoned on every failure.
/// Total request size is bounded independently of each backend's file quota.
pub fn consume(
  reader: transport.BodyReader(state),
  store: attachment_store.Store,
  expires: Int,
  maximum_request_bytes: Int,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  case store.begin(attachment_store.BeginUpload(expires:)) {
    Error(error) -> {
      transport.cancel_body(reader)
      Error(error)
    }
    Ok(handle) -> consume_loop(reader, store, handle, maximum_request_bytes, 0)
  }
}

fn consume_loop(
  reader: transport.BodyReader(state),
  store: attachment_store.Store,
  handle: attachment_store.UploadHandle,
  maximum_request_bytes: Int,
  bytes_read: Int,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  case transport.read(reader, maximum_chunk_bytes) {
    Error(transport.BodyTooLarge(limit)) ->
      fail(reader, store, handle, attachment_store.TooLarge(limit, limit + 1))
    Error(transport.BodyUnavailable) | Error(transport.BodyCancelled) ->
      fail(
        reader,
        store,
        handle,
        attachment_store.Unavailable("request body stream was interrupted"),
      )
    Ok(#(transport.BodyEnd, _)) ->
      case store.finish(handle) {
        Ok(stored) -> Ok(stored)
        Error(error) -> fail(reader, store, handle, error)
      }
    Ok(#(transport.BodyChunk(chunk), next)) -> {
      let actual = bytes_read + bit_array.byte_size(chunk)
      case actual > maximum_request_bytes {
        True ->
          fail(
            next,
            store,
            handle,
            attachment_store.TooLarge(maximum_request_bytes, actual),
          )
        False ->
          case store.write(handle, chunk) {
            Error(error) -> fail(next, store, handle, error)
            Ok(_) ->
              consume_loop(next, store, handle, maximum_request_bytes, actual)
          }
      }
    }
  }
}

fn fail(
  reader: transport.BodyReader(state),
  store: attachment_store.Store,
  handle: attachment_store.UploadHandle,
  error: attachment_store.Error,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  let _ = store.abort(handle)
  transport.cancel_body(reader)
  Error(error)
}
