# Bounded message templates

Notify implements the ntfy v2.27 message-template protocol independently. It
does not embed ntfy template files, Go's `text/template`, or Sprig. The fixed
v2.27 container is used as a black-box compatibility oracle.

## Enabling templates

For inline templates, set `X-Template` (aliases `Template` or `Tpl`) to any of
`yes`, `1`, `true`, `no`, `0`, or `false`. The last three values enabling the
mode is an intentional v2.27 compatibility quirk. Header values take precedence
over `template` and `tpl` query values.

The request body must be JSON. `X-Message`, `X-Title`, and `X-Priority` (and
their ordinary ntfy aliases) are rendered against that JSON value. For a JSON
publish to `/`, the nested `message` string is the template data source.

```sh
curl -X POST https://notify.example/alerts \
  -H 'Template: yes' \
  -H 'Message: {{.service | upper}} is {{.state}}' \
  -H 'Title: Alert: {{.service}}' \
  -H 'Priority: {{.severity}}' \
  -d '{"service":"database","state":"down","severity":"high"}'
```

Named built-ins are `github`, `grafana`, and `alertmanager`. Their
transformations are native Notify code rather than copied YAML assets. A custom
file with the same name takes precedence.

## Custom files

Set the directory with one of these equivalent configuration paths:

```toml
[templates]
directory = "/srv/notify/templates"
```

```sh
NOTIFY_TEMPLATE_DIRECTORY=/srv/notify/templates notify serve
notify serve --template-dir /srv/notify/templates
```

A request for `Template: deploy` reads only
`/srv/notify/templates/deploy.yml`. Names must match
`[-_A-Za-z0-9]+`; separators and traversal components are rejected. Files use a
narrow YAML profile with top-level `message`, `title`, and `priority` string
scalars. Plain, single-quoted, double-quoted, literal block (`|`), and folded
block (`>`) strings are accepted. Unknown or duplicate keys and malformed
indentation fail with ntfy code `40048`. Files must be regular (not symlinks)
and no larger than 96 KiB.

```yaml
title: 'Deploy {{.service}}'
message: |-
  {{.service | upper}} is {{.state}}
priority: '{{if eq .state "failed"}}high{{else}}default{{end}}'
```

## Language and safe functions

Field lookup (`.field`, nested paths, and `$` root), variables, pipelines,
parenthesised pipelines, `if`/`else`, `with`, `range`, `break`, `continue`, and
whitespace trim markers are supported. Missing fields render as `<no value>`.
`define`, `template`, `block`, and `call` are rejected before execution.

The allowlist currently contains:

- core: `and`, `or`, `not`, `len`, `index`, `slice`, `print`, `printf`,
  `println`, `eq`, `ne`, `lt`, `le`, `gt`, `ge`;
- strings: `trim`, `trimAll`, `trimPrefix`, `trimSuffix`, `upper`, `lower`,
  `title`, `repeat`, `substr`, `trunc`, `contains`, `hasPrefix`, `hasSuffix`,
  `quote`, `squote`, `cat`, `indent`, `nindent`, `replace`, `plural`,
  `toString`, `atoi`;
- math and sequences: `until`, `untilStep`, `add1`, `add`, `sub`, `div`,
  `mod`, `mul`, `max`, `min`, `maxf`, `minf`, `ceil`, `floor`, `round`;
- collections/defaults: `join`, `sortAlpha`, `default`, `empty`, `coalesce`,
  `all`, `any`, `compact`, `list`, `tuple`, `dict`, `get`, `hasKey`, `keys`,
  `values`, `append`, `push`, `prepend`, `first`, `rest`, `last`, `initial`,
  `reverse`, `uniq`, `without`, `has`, `concat`, `dig`, `chunk`, `ternary`;
- encoding/reflection: `fromJSON`, `toJSON`, `toPrettyJSON`, `toRawJSON`,
  `typeOf`, `typeIs`, `typeIsLike`, `kindOf`, `kindIs`, `deepEqual`, `b64enc`,
  `b64dec`, `b32enc`, `b32dec`, `sha1sum`, `sha256sum`, `sha512sum`,
  `adler32sum`;
- slash-path helpers: `base`, `dir`, `clean`, `ext`, `isAbs`; and
- explicit failure: `fail`.

Environment, filesystem, process, random, network, and command execution are
not reachable from templates. The v2.27 date, regex, URL, OS-path,
mutable-dictionary, `must*`, and several advanced conversion helpers are not
implemented yet; see the compatibility matrix before relying on general Sprig
or Go-template portability.

## Resource and error contract

Every field render runs in a monitored BEAM process which is killed after 100
milliseconds. Deterministic instruction, parser/evaluator depth, 10,000-item
loop/list, 100,000-byte generated-string, 100-space indentation, and guarded
`printf` limits stop amplification even before that deadline. `printf` widths
and precisions must be below 1,000 and dynamic `*` widths are rejected.

| Boundary | Limit | Error |
| --- | ---: | ---: |
| JSON source | 128 KiB | `41303` |
| Custom template file | 96 KiB | `40048` |
| Each template | 32 KiB | `40056` |
| Intermediate output | 1 MiB | `40045` |
| Final message or title | 4,096 UTF-8 bytes | `40041` |
| Execution deadline | 100 ms | `40055` |

Malformed JSON is `40042`, syntax or a non-allowlisted function is `40043`, a
disallowed template feature is `40044`, other execution failures are `40045`,
and missing/invalid named files are `40047`/`40048`. A failed render never
commits a message or event.
