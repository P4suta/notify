import gleam/option.{None, Some}
import notify/core/action
import notify/core/message

pub fn parses_simple_actions_and_options_test() {
  let assert Ok(actions) =
    action.parse(
      "view, Open portal, https://example.test, clear=true; http, Turn down, https://api.example.test/device, method=PUT, body=target=65, headers.Authorization=Bearer token; copy, Copy code, 1234",
    )
  assert actions
    == [
      message.ViewAction(
        label: "Open portal",
        url: "https://example.test",
        clear: True,
        id: None,
      ),
      message.HttpAction(
        label: "Turn down",
        url: "https://api.example.test/device",
        method: "PUT",
        headers: [#("Authorization", "Bearer token")],
        body: Some("target=65"),
        clear: False,
        id: None,
      ),
      message.CopyAction(
        label: "Copy code",
        value: "1234",
        clear: False,
        id: None,
      ),
    ]
}

pub fn quoted_commas_and_json_are_supported_test() {
  let assert Ok(simple) =
    action.parse("view, \"Look, commas; and quotes\", https://example.test")
  assert simple
    == [
      message.ViewAction(
        label: "Look, commas; and quotes",
        url: "https://example.test",
        clear: False,
        id: None,
      ),
    ]

  let assert Ok(json) =
    action.parse(
      "[{\"action\":\"copy\",\"label\":\"OTP\",\"value\":\"567890\"}]",
    )
  assert json
    == [
      message.CopyAction(label: "OTP", value: "567890", clear: False, id: None),
    ]
}

pub fn rejects_invalid_action_constraints_test() {
  assert action.parse("not-an-action")
    == Error(action.InvalidActionKind("not-an-action"))
  assert action.parse("copy, Missing value") == Error(action.InvalidAction)
  assert action.parse(
      "http, No body on GET, https://example.test, method=GET, body=x",
    )
    == Error(action.InvalidAction)
  assert action.parse(
      "view,a,https://a;view,b,https://b;view,c,https://c;view,d,https://d",
    )
    == Error(action.TooManyActions)
  assert action.parse("") == Ok([])
  assert action.parse("view,Open,https://example.test,clear=maybe")
    == Error(action.InvalidAction)
  assert action.parse("http,Send,https://example.test,headers. =missing-name")
    == Error(action.InvalidAction)
  assert action.parse("view,Open,https://example.test,UnexpectedHeader=value")
    == Error(action.InvalidAction)
  assert action.parse(
      "[{\"action\":\"view\",\"label\":\"a\",\"url\":\"https://a\"},{\"action\":\"view\",\"label\":\"b\",\"url\":\"https://b\"},{\"action\":\"view\",\"label\":\"c\",\"url\":\"https://c\"},{\"action\":\"view\",\"label\":\"d\",\"url\":\"https://d\"}]",
    )
    == Error(action.TooManyActions)
}

pub fn explicit_keys_are_trimmed_case_insensitively_and_all_fields_survive_test() {
  let assert Ok(view) =
    action.parse(
      " Action = VIEW, Label = Open, URL = https://example.test, Clear = NO",
    )
  assert view
    == [
      message.ViewAction(
        label: "Open",
        url: "https://example.test",
        clear: False,
        id: None,
      ),
    ]

  let assert Ok(http) =
    action.parse(
      "Action=http,Label=Send,URL=https://api.example.test,Method=patch,Headers. X-Trace = request-42,Body=payload",
    )
  assert http
    == [
      message.HttpAction(
        label: "Send",
        url: "https://api.example.test",
        method: "PATCH",
        headers: [#("X-Trace", "request-42")],
        body: Some("payload"),
        clear: False,
        id: None,
      ),
    ]

  let assert Ok(copy) =
    action.parse("Action=copy,Label=Copy,Value=42,Clear=false")
  assert copy
    == [message.CopyAction(label: "Copy", value: "42", clear: False, id: None)]
}

pub fn simple_action_defaults_and_empty_fields_are_validated_independently_test() {
  let assert Ok(http) = action.parse("http, Send, https://api.example.test")
  assert http
    == [
      message.HttpAction(
        label: "Send",
        url: "https://api.example.test",
        method: "POST",
        headers: [],
        body: None,
        clear: False,
        id: None,
      ),
    ]

  assert action.parse("view,,https://example.test")
    == Error(action.InvalidAction)
  assert action.parse("view,Open,") == Error(action.InvalidAction)
  assert action.parse("http,,https://example.test")
    == Error(action.InvalidAction)
  assert action.parse("http,Send,") == Error(action.InvalidAction)
  assert action.parse("copy,,42") == Error(action.InvalidAction)
  assert action.parse("copy,Copy,") == Error(action.InvalidAction)
  assert action.parse(
      "http,No body on HEAD,https://example.test,method=HEAD,body=x",
    )
    == Error(action.InvalidAction)
}

pub fn json_actions_receive_the_same_validation_as_simple_actions_test() {
  assert action.parse(
      "[{\"action\":\"view\",\"label\":\"\",\"url\":\"https://example.test\"}]",
    )
    == Error(action.InvalidAction)
  assert action.parse("[{\"action\":\"view\",\"label\":\"Open\",\"url\":\"\"}]")
    == Error(action.InvalidAction)
  assert action.parse("[{\"action\":\"copy\",\"label\":\"\",\"value\":\"42\"}]")
    == Error(action.InvalidAction)
  assert action.parse(
      "[{\"action\":\"copy\",\"label\":\"Copy\",\"value\":\"\"}]",
    )
    == Error(action.InvalidAction)
  assert action.parse(
      "[{\"action\":\"http\",\"label\":\"\",\"url\":\"https://example.test\"}]",
    )
    == Error(action.InvalidAction)
  assert action.parse("[{\"action\":\"http\",\"label\":\"Send\",\"url\":\"\"}]")
    == Error(action.InvalidAction)
  assert action.parse(
      "[{\"action\":\"http\",\"label\":\"Send\",\"url\":\"https://example.test\",\"method\":\"get\",\"body\":\"x\"}]",
    )
    == Error(action.InvalidAction)
  assert action.parse(
      "[{\"action\":\"http\",\"label\":\"Send\",\"url\":\"https://example.test\",\"method\":\"HEAD\",\"body\":\"x\"}]",
    )
    == Error(action.InvalidAction)
}

pub fn quotes_escapes_and_syntax_errors_are_preserved_test() {
  let assert Ok(escaped) =
    action.parse(
      "view, \"Open \\\"now\\\", please; safely\", https://example.test",
    )
  assert escaped
    == [
      message.ViewAction(
        label: "Open \"now\", please; safely",
        url: "https://example.test",
        clear: False,
        id: None,
      ),
    ]

  let assert Ok(starts_quoted) =
    action.parse("view, \"\\\"Quoted\\\" label\", https://example.test")
  assert starts_quoted
    == [
      message.ViewAction(
        label: "\"Quoted\" label",
        url: "https://example.test",
        clear: False,
        id: None,
      ),
    ]

  assert action.parse("view, \"unterminated, https://example.test")
    == Error(action.InvalidSyntax)
}
