import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import notify/attachment_store/filesystem
import notify/core/message
import notify/core/message_json
import notify/http/router
import notify/runtime
import notify/storage/memory

fn body(response: Response(BitArray)) -> String {
  let assert Ok(value) = bit_array.to_string(response.body)
  value
}

fn test_runtime() -> runtime.Runtime {
  let assert Ok(storage) = memory.start()
  runtime.new(
    storage:,
    clock: runtime.Clock(fn() { 1_725_000_000 }),
    ids: runtime.IdGenerator(fn() { "AbCdEf1234XY" }),
    retention_seconds: 43_200,
  )
}

fn publish(
  path: String,
  source: String,
  parameters: List(#(String, String)),
) -> Response(BitArray) {
  parameters
  |> list.fold(
    request.new()
      |> request.set_method(http.Put)
      |> request.set_path(path)
      |> request.set_body(bit_array.from_string(source)),
    fn(req, parameter) { request.set_header(req, parameter.0, parameter.1) },
  )
  |> router.handle(test_runtime())
}

fn decoded(response: Response(BitArray)) -> message.Message {
  let assert Ok(value) = json.parse(body(response), message_json.decoder())
  value
}

fn assert_error(response: Response(BitArray), code: Int) {
  assert response.status == 400
  assert string.contains(body(response), "\"code\":" <> int.to_string(code))
}

pub fn inline_template_renders_nested_fields_and_aliases_test() {
  let response =
    publish(
      "/alerts",
      "{\"name\":\"database\",\"nested\":{\"state\":\"down\"}}",
      [
        #("tpl", "yes"),
        #("m", "{{.name}} is {{.nested.state}}"),
        #("t", "Alert: {{.name | upper}}"),
      ],
    )

  assert response.status == 200
  let value = decoded(response)
  assert value.message == "database is down"
  assert value.title == option.Some("Alert: DATABASE")
}

pub fn root_json_publish_templates_its_nested_message_field_test() {
  let response =
    publish(
      "/",
      "{\"topic\":\"alerts\",\"message\":\"{\\\"name\\\":\\\"database\\\",\\\"severity\\\":\\\"high\\\"}\"}",
      [
        #("x-template", "1"),
        #("x-message", "{{.name}} is down"),
        #("x-priority", "{{.severity}}"),
      ],
    )

  assert response.status == 200
  let value = decoded(response)
  assert value.message == "database is down"
  assert value.priority == message.High
}

pub fn template_range_condition_pipeline_and_newline_contract_test() {
  let response =
    publish(
      "/alerts",
      "{\"errors\":[{\"level\":\"severe\",\"url\":\"a\"},{\"level\":\"warning\",\"url\":\"b\"},{\"level\":\"severe\",\"url\":\"c\"}]}",
      [
        #("template", "true"),
        #(
          "message",
          "Severe URLs:\\n{{range .errors}}{{if eq .level \"severe\"}}- {{.url | upper}}\\n{{end}}{{end}}",
        ),
      ],
    )

  assert response.status == 200
  assert decoded(response).message == "Severe URLs:\n- A\n- C"
}

pub fn template_missing_field_and_if_else_match_go_truthiness_test() {
  let response =
    publish("/alerts", "{\"enabled\":false,\"items\":[]}", [
      #("x-template", "yes"),
      #(
        "x-message",
        "{{.missing}}/{{if .enabled}}on{{else}}off{{end}}/{{with .items}}items{{else}}empty{{end}}",
      ),
    ])

  assert response.status == 200
  assert decoded(response).message == "<no value>/off/empty"
}

pub fn template_boolean_looking_values_enable_inline_mode_like_v227_test() {
  ["yes", "1", "true", "no", "0", "false"]
  |> list.each(fn(enabled) {
    let response =
      publish("/alerts", "{\"value\":\"rendered\"}", [
        #("template", enabled),
        #("message", "{{.value}}"),
      ])
    assert response.status == 200
    assert decoded(response).message == "rendered"
  })
}

pub fn inline_template_without_message_template_defaults_to_triggered_test() {
  let response =
    publish("/alerts", "{\"value\":\"data only\"}", [
      #("template", "yes"),
      #("title", "{{.value}}"),
    ])

  assert response.status == 200
  let value = decoded(response)
  assert value.message == "triggered"
  assert value.title == option.Some("data only")
}

pub fn malformed_template_source_is_rejected_without_commit_test() {
  let runtime = test_runtime()
  let response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "yes")
    |> request.set_header("message", "{{.value}}")
    |> request.set_body(<<"not json":utf8>>)
    |> router.handle(runtime)
  assert_error(response, 40_042)

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert body(poll) == ""
}

pub fn invalid_unsafe_and_disallowed_templates_have_distinct_errors_test() {
  let invalid =
    publish("/alerts", "{}", [#("template", "yes"), #("message", "{{if}}")])
  assert_error(invalid, 40_043)

  let unsafe =
    publish("/alerts", "{}", [
      #("template", "yes"),
      #("message", "{{env \"PATH\"}}"),
    ])
  assert_error(unsafe, 40_043)

  [
    "{{call .fn}}",
    "{{template \"other\"}}",
    "{{define \"other\"}}x{{end}}",
    "{{block \"other\" .}}x{{end}}",
  ]
  |> list.each(fn(source) {
    let response =
      publish("/alerts", "{\"fn\":1}", [
        #("template", "yes"),
        #("message", source),
      ])
    assert_error(response, 40_044)
  })
}

pub fn template_size_output_and_final_message_limits_are_separate_test() {
  let source_too_large =
    publish("/alerts", "{}", [
      #("template", "yes"),
      #("message", "{{print \"x\"}}" <> string.repeat("x", times: 32_768)),
    ])
  assert_error(source_too_large, 40_056)

  let final_message_too_large =
    publish("/alerts", "{}", [
      #("template", "yes"),
      #("message", "{{repeat 4097 \"x\"}}"),
    ])
  assert_error(final_message_too_large, 40_041)

  let function_limit =
    publish("/alerts", "{}", [
      #("template", "yes"),
      #("message", "{{repeat 10001 \"x\"}}"),
    ])
  assert_error(function_limit, 40_045)
}

pub fn template_printf_amplification_is_rejected_but_small_width_works_test() {
  let valid =
    publish("/alerts", "{\"n\":7}", [
      #("template", "yes"),
      #("message", "{{printf \"%05d\" .n}}"),
    ])
  assert valid.status == 200
  assert decoded(valid).message == "00007"

  ["{{printf \"%1000d\" 1}}", "{{printf \"%*d\" 10 1}}"]
  |> list.each(fn(source) {
    publish("/alerts", "{}", [#("template", "yes"), #("message", source)])
    |> assert_error(40_045)
  })
}

pub fn dynamic_printf_indent_and_generated_list_amplification_are_bounded_test() {
  [
    "{{$f := print \"%\" \"1000000\" \"d\"}}{{printf $f 1}}",
    "{{indent 101 \"value\"}}",
    "{{range until 10001}}{{.}}{{end}}",
  ]
  |> list.each(fn(source) {
    publish("/alerts", "{}", [#("template", "yes"), #("message", source)])
    |> assert_error(40_045)
  })
}

pub fn template_json_source_intermediate_output_and_recursion_have_separate_limits_test() {
  let source_too_large =
    publish("/alerts", string.repeat(" ", times: 131_073), [
      #("template", "yes"),
      #("message", "ok"),
    ])
  assert source_too_large.status == 413
  assert string.contains(body(source_too_large), "\"code\":41303")

  let items = list.repeat("0", times: 40) |> string.join(",")
  let output_too_large =
    publish("/alerts", "{\"items\":[" <> items <> "]}", [
      #("template", "yes"),
      #(
        "message",
        "{{range .items}}" <> string.repeat("x", times: 30_000) <> "{{end}}",
      ),
    ])
  assert_error(output_too_large, 40_045)

  let too_deep =
    publish("/alerts", "{}", [
      #("template", "yes"),
      #(
        "message",
        string.repeat("{{if true}}", times: 65)
          <> "ok"
          <> string.repeat("{{end}}", times: 65),
      ),
    ])
  assert_error(too_deep, 40_043)
}

pub fn template_assignments_root_scope_comments_and_trim_markers_test() {
  let response =
    publish("/alerts", "{\"prefix\":\"API\",\"items\":[\"a\",\"b\"]}", [
      #("template", "yes"),
      #(
        "message",
        "   {{- /* private comment */ -}} {{$prefix := .prefix}}{{range $index, $item := .items}}{{if $index}},{{end}}{{$prefix}}:{{$item}}{{end}} ",
      ),
    ])

  assert response.status == 200
  assert decoded(response).message == "API:a,API:b"
}

pub fn template_outer_assignment_rune_print_replace_and_round_contract_test() {
  let response =
    publish("/alerts", "{\"items\":[\"a\",\"b\"]}", [
      #("template", "yes"),
      #(
        "message",
        "{{$count := 0}}{{range .items}}{{$count = add $count 1}}{{end}}{{$count}}/{{'A'}}/{{print 1 2 \"x\" 3 4}}/{{replace \"\" \"-\" \"ab\"}}/{{round 1.2345 2}}",
      ),
    ])

  assert response.status == 200
  assert decoded(response).message == "2/65/1 2x3 4/-a-b-/1.23"
}

pub fn template_json_number_pretty_encoding_and_round_threshold_contract_test() {
  let response =
    publish(
      "/alerts",
      "{\"n\":1,\"obj\":{\"b\":2,\"a\":1},\"html\":\"<tag>&\"}",
      [
        #("template", "yes"),
        #(
          "message",
          "{{typeOf .n}}|{{kindOf .n}}|{{.n}}|{{toPrettyJSON .obj}}|{{round 1.25 1 0.6}}|{{toJSON .html}}|{{toRawJSON .html}}",
        ),
      ],
    )

  assert response.status == 200
  assert decoded(response).message
    == "float64|float64|1|{\n  \"a\": 1,\n  \"b\": 2\n}|1.2|\"\\u003ctag\\u003e\\u0026\"|\"<tag>&\""
}

pub fn data_driven_nested_range_is_bounded_and_never_published_test() {
  let numbers =
    list.repeat("0", times: 1000)
    |> string.join(",")
  let response =
    publish("/alerts", "{\"a\":[" <> numbers <> "]}", [
      #("template", "yes"),
      #(
        "message",
        "{{range .a}}{{range $.a}}{{range $.a}}{{$x := .}}{{end}}{{end}}{{end}}done",
      ),
    ])
  assert_error(response, 40_055)
}

pub fn custom_named_template_renders_all_fields_and_overrides_builtin_test() {
  let assert Ok(raw_directory) = filesystem.temporary_directory()
  let directory = string.trim_end(raw_directory)
  let template =
    "title: |-\n"
    <> "  Deploy {{.service}}\n"
    <> "message: |-\n"
    <> "  {{.service | upper}}: {{.state}}\n"
    <> "priority: '{{if eq .state \"failed\"}}high{{else}}default{{end}}'\n"
  assert write_binary_file(
      directory <> "/grafana.yml",
      bit_array.from_string(template),
    )
    == Ok(Nil)

  let runtime =
    test_runtime()
    |> runtime.with_template_directory(directory)
  let response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "grafana")
    |> request.set_body(<<"{\"service\":\"api\",\"state\":\"failed\"}":utf8>>)
    |> router.handle(runtime)

  assert response.status == 200
  let value = decoded(response)
  assert value.title == option.Some("Deploy api")
  assert value.message == "API: failed"
  assert value.priority == message.High
}

pub fn custom_named_template_supports_safe_folded_yaml_scalars_test() {
  let assert Ok(raw_directory) = filesystem.temporary_directory()
  let directory = string.trim_end(raw_directory)
  let template =
    "title: \"Deploy {{.service}}\"\n"
    <> "message: >-\n"
    <> "  Service {{.service}}\n"
    <> "  is {{.state}}\n"
  assert write_binary_file(
      directory <> "/deploy.yml",
      bit_array.from_string(template),
    )
    == Ok(Nil)
  let runtime =
    test_runtime()
    |> runtime.with_template_directory(directory)
  let response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "deploy")
    |> request.set_body(<<"{\"service\":\"api\",\"state\":\"healthy\"}":utf8>>)
    |> router.handle(runtime)

  assert response.status == 200
  assert decoded(response).message == "Service api is healthy"
}

pub fn named_template_keeps_message_parameter_and_ignores_priority_parameter_test() {
  let assert Ok(raw_directory) = filesystem.temporary_directory()
  let directory = string.trim_end(raw_directory)
  assert write_binary_file(directory <> "/title-only.yml", <<
      "title: 'Deploy {{.service}}'\n":utf8,
    >>)
    == Ok(Nil)
  let runtime =
    test_runtime()
    |> runtime.with_template_directory(directory)
  let response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "title-only")
    |> request.set_header("message", "deployment event")
    |> request.set_header("priority", "{{.severity}}")
    |> request.set_body(<<"{\"service\":\"api\",\"severity\":\"high\"}":utf8>>)
    |> router.handle(runtime)

  assert response.status == 200
  let value = decoded(response)
  assert value.message == "deployment event"
  assert value.title == option.Some("Deploy api")
  assert value.priority == message.Default
}

pub fn named_template_missing_invalid_and_traversal_errors_are_distinct_test() {
  let assert Ok(raw_directory) = filesystem.temporary_directory()
  let directory = string.trim_end(raw_directory)
  assert write_binary_file(directory <> "/broken.yml", <<
      "unknown: value\n":utf8,
    >>)
    == Ok(Nil)
  let runtime =
    test_runtime()
    |> runtime.with_template_directory(directory)

  ["missing", "../secret", "bad/name"]
  |> list.each(fn(name) {
    let response =
      request.new()
      |> request.set_method(http.Put)
      |> request.set_path("/alerts")
      |> request.set_header("template", name)
      |> request.set_body(<<"{}":utf8>>)
      |> router.handle(runtime)
    assert_error(response, 40_047)
  })

  let invalid =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "broken")
    |> request.set_body(<<"{}":utf8>>)
    |> router.handle(runtime)
  assert_error(invalid, 40_048)
}

pub fn oversized_named_template_file_is_rejected_before_render_test() {
  let assert Ok(raw_directory) = filesystem.temporary_directory()
  let directory = string.trim_end(raw_directory)
  assert write_binary_file(
      directory <> "/oversized.yml",
      bit_array.from_string(
        "message: " <> string.repeat("x", times: 98_305) <> "\n",
      ),
    )
    == Ok(Nil)
  let runtime =
    test_runtime()
    |> runtime.with_template_directory(directory)
  let response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/alerts")
    |> request.set_header("template", "oversized")
    |> request.set_body(<<"{}":utf8>>)
    |> router.handle(runtime)

  assert_error(response, 40_048)
}

pub fn independently_implemented_grafana_builtin_matches_v227_output_test() {
  let response =
    publish(
      "/alerts",
      "{\"status\":\"resolved\",\"title\":\"Database recovered\",\"message\":\"Connections are healthy\"}",
      [#("template", "grafana")],
    )

  assert response.status == 200
  let value = decoded(response)
  assert value.title == option.Some("✅ Database recovered")
  assert value.message == "Connections are healthy"
}

pub fn independently_implemented_alertmanager_builtin_formats_alerts_test() {
  let response =
    publish(
      "/alerts",
      "{\"status\":\"firing\",\"receiver\":\"on-call\",\"alerts\":[{\"labels\":{\"alertname\":\"DiskFull\",\"instance\":\"db-1\",\"severity\":\"critical\"},\"annotations\":{\"summary\":\"Disk at 99%\"},\"startsAt\":\"now\",\"endsAt\":\"\",\"generatorURL\":\"https://monitor.example/1\"}]}",
      [#("template", "alertmanager")],
    )

  assert response.status == 200
  let value = decoded(response)
  assert value.title == option.Some("🚨 Alert: DiskFull")
  assert string.contains(value.message, "Status: Firing")
  assert string.contains(value.message, "Summary: Disk at 99%")
  assert string.contains(value.message, "Source: https://monitor.example/1")
}

@external(erlang, "notify_ffi", "write_binary_file")
fn write_binary_file(path: String, data: BitArray) -> Result(Nil, String)
