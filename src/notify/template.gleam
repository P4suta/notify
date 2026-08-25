import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None}
import gleam/result

/// Errors are deliberately coarse and stable. Parser and evaluator details are
/// never reflected into an HTTP response because templates frequently contain
/// webhook field names that operators do not intend to log or disclose.
pub type Error {
  SourceTooLarge
  SourceNotJson
  TemplateTooLarge
  InvalidTemplate
  DisallowedFeature
  ExecutionFailed
  ExecutionTimedOut
}

pub type Definition {
  Definition(
    title: Option(String),
    message: Option(String),
    priority: Option(String),
  )
}

pub type FileError {
  FileNotFound
  FileInvalid
}

pub const max_source_bytes = 131_072

pub const max_template_bytes = 32_768

pub const max_output_bytes = 1_048_576

/// Renders the independently implemented, bounded ntfy v2.27 template
/// language. The BEAM worker is isolated and forcefully cancelled after
/// 100 milliseconds in addition to deterministic instruction/depth limits.
pub fn render(source: String, template: String) -> Result(String, Error) {
  case byte_size(source), byte_size(template) {
    source_size, _ if source_size > max_source_bytes -> Error(SourceTooLarge)
    _, template_size if template_size > max_template_bytes ->
      Error(TemplateTooLarge)
    _, _ ->
      render_ffi(source, template)
      |> map_error
  }
}

/// Loads only the intentionally narrow template-file format: a UTF-8 `.yml`
/// file with top-level `title`, `message`, and/or `priority` scalars. The file
/// adapter validates the name before joining it to the configured directory.
pub fn load_file(
  directory: String,
  name: String,
) -> Result(Definition, FileError) {
  case load_file_ffi(directory, name) {
    Ok(fields) -> definition(fields) |> result.map_error(fn(_) { FileInvalid })
    Error("not_found") -> Error(FileNotFound)
    Error(_) -> Error(FileInvalid)
  }
}

/// Renders one of the three v2.27 built-ins using independent transformations,
/// rather than embedding or copying ntfy's YAML assets.
pub fn render_builtin(
  source: String,
  name: String,
) -> Result(Definition, Error) {
  case byte_size(source) > max_source_bytes {
    True -> Error(SourceTooLarge)
    False ->
      render_builtin_ffi(source, name)
      |> map_definition_error
  }
}

fn byte_size(value: String) -> Int {
  value
  |> bit_array.from_string
  |> bit_array.byte_size
}

fn map_error(result: Result(String, String)) -> Result(String, Error) {
  case result {
    Ok(rendered) -> Ok(rendered)
    Error("source_not_json") -> Error(SourceNotJson)
    Error("template_too_large") -> Error(TemplateTooLarge)
    Error("invalid_template") -> Error(InvalidTemplate)
    Error("disallowed") -> Error(DisallowedFeature)
    Error("timeout") -> Error(ExecutionTimedOut)
    Error(_) -> Error(ExecutionFailed)
  }
}

fn map_definition_error(
  result: Result(List(#(String, String)), String),
) -> Result(Definition, Error) {
  case result {
    Ok(fields) ->
      definition(fields)
      |> result.map_error(fn(_) { ExecutionFailed })
    Error("source_not_json") -> Error(SourceNotJson)
    Error("timeout") -> Error(ExecutionTimedOut)
    Error("not_found") -> Error(InvalidTemplate)
    Error(_) -> Error(ExecutionFailed)
  }
}

fn definition(fields: List(#(String, String))) -> Result(Definition, Nil) {
  let title = field(fields, "title")
  let message = field(fields, "message")
  let priority = field(fields, "priority")
  case title, message, priority {
    None, None, None -> Error(Nil)
    _, _, _ -> Ok(Definition(title:, message:, priority:))
  }
}

fn field(fields: List(#(String, String)), name: String) -> Option(String) {
  fields
  |> list.find_map(fn(field) {
    case field.0 == name {
      True -> Ok(field.1)
      False -> Error(Nil)
    }
  })
  |> option.from_result
}

@external(erlang, "notify_template_ffi", "render")
fn render_ffi(source: String, template: String) -> Result(String, String)

@external(erlang, "notify_template_ffi", "load_file")
fn load_file_ffi(
  directory: String,
  name: String,
) -> Result(List(#(String, String)), String)

@external(erlang, "notify_template_ffi", "render_builtin")
fn render_builtin_ffi(
  source: String,
  name: String,
) -> Result(List(#(String, String)), String)
