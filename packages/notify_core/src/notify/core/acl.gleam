import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Role {
  User
  Admin
}

pub type Principal {
  Anonymous
  Authenticated(username: String, role: Role)
}

pub type Permission {
  Deny
  ReadOnly
  WriteOnly
  ReadWrite
}

pub type Operation {
  Read
  Write
}

pub type Rule {
  Rule(username: String, topic_pattern: String, permission: Permission)
}

type Candidate {
  Candidate(
    specificity: RuleSpecificity,
    pattern_length: Int,
    permission: Permission,
  )
}

type RuleSpecificity {
  EveryoneRule
  UserRule
}

type OwnerFilter {
  AnonymousOwner
  AuthenticatedOwner(String)
}

/// Resolves ACLs using ntfy v2.27.0 precedence: a user-specific rule beats
/// everyone, a longer matching pattern beats a shorter one, and a
/// write-capable rule wins when lengths are equal.
pub fn authorize(
  principal: Principal,
  topic: String,
  operation: Operation,
  rules: List(Rule),
  fallback: Permission,
) -> Bool {
  case principal {
    Authenticated(_, Admin) -> True
    Anonymous ->
      rules
      |> best_rule(AnonymousOwner, topic)
      |> selected_permission(fallback)
      |> allows(operation)
    Authenticated(username, User) ->
      rules
      |> best_rule(AuthenticatedOwner(username), topic)
      |> selected_permission(fallback)
      |> allows(operation)
  }
}

fn best_rule(
  rules: List(Rule),
  owner_filter: OwnerFilter,
  topic: String,
) -> Option(Candidate) {
  list.fold(rules, None, fn(best, rule) {
    let Rule(owner, pattern, permission) = rule
    case
      owner_specificity(owner, owner_filter),
      pattern_matches(pattern, topic)
    {
      Some(specificity), True -> {
        let candidate =
          Candidate(
            specificity:,
            pattern_length: string.length(pattern),
            permission:,
          )
        case best {
          None -> Some(candidate)
          Some(current) ->
            case outranks(candidate, current) {
              True -> Some(candidate)
              False -> best
            }
        }
      }
      _, _ -> best
    }
  })
}

fn owner_specificity(
  owner: String,
  owner_filter: OwnerFilter,
) -> Option(RuleSpecificity) {
  case owner_filter, owner {
    AnonymousOwner, "*" -> Some(EveryoneRule)
    AuthenticatedOwner(_), "*" -> Some(EveryoneRule)
    AuthenticatedOwner(username), owner if username == owner -> Some(UserRule)
    _, _ -> None
  }
}

fn outranks(candidate: Candidate, current: Candidate) -> Bool {
  case candidate.specificity, current.specificity {
    UserRule, EveryoneRule -> True
    EveryoneRule, UserRule -> False
    _, _ if candidate.pattern_length > current.pattern_length -> True
    _, _ if candidate.pattern_length < current.pattern_length -> False
    _, _ -> can_write(candidate.permission) && !can_write(current.permission)
  }
}

fn selected_permission(
  candidate: Option(Candidate),
  fallback: Permission,
) -> Permission {
  case candidate {
    None -> fallback
    Some(candidate) -> candidate.permission
  }
}

pub fn allows(permission: Permission, operation: Operation) -> Bool {
  case permission, operation {
    ReadWrite, _ -> True
    ReadOnly, Read -> True
    WriteOnly, Write -> True
    _, _ -> False
  }
}

fn can_write(permission: Permission) -> Bool {
  allows(permission, Write)
}

pub fn pattern_matches(pattern: String, topic: String) -> Bool {
  wildcard_match(string.to_graphemes(pattern), string.to_graphemes(topic))
}

fn wildcard_match(pattern: List(String), value: List(String)) -> Bool {
  case pattern, value {
    [], [] -> True
    [], [_, ..] -> False
    ["*", ..rest], [] -> wildcard_match(rest, [])
    ["*", ..rest] as pattern, [_, ..value_rest] ->
      wildcard_match(rest, value) || wildcard_match(pattern, value_rest)
    [pattern_head, ..pattern_rest], [value_head, ..value_rest]
      if pattern_head == value_head
    -> wildcard_match(pattern_rest, value_rest)
    _, _ -> False
  }
}
