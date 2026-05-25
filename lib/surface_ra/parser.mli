(** Parser for the relational-algebra query language.

    Built on [angstrom]. A top-level input is a relational pipeline -- a base
    relation reference followed by zero or more pipe-separated steps:
    [restrict <predicate>], [project <columns>], [cross <relation>],
    [join <relation> on <predicate>], [type], and optionally a terminal sink
    ([insert into <table>]). Whitespace surrounding tokens is tolerated;
    anything else (extra tokens, malformed identifiers, empty input, a leading
    [:] sigil from the retired DDL grammar) is rejected.

    The error type is currently a string passed straight from angstrom. When
    user-visible errors gain location information or structured cases this
    becomes a proper variant; the {!type-error} alias exists now so callers can
    already speak in terms of [Parser.error] rather than coupling to [string].
*)

module Expression = Dovetail_core.Expression

type error = string
(** Placeholder for parser errors. The string is whatever angstrom produced. *)

val parse : string -> (Ast.program, error) result
(** [parse input] parses [input] as a complete top-level program. The result is
    always an {!Ast.Pipeline} carrying an {!Ast.t} ([Ast.Insert] sits inside [t]
    as a regular operator); the {!Ast.Ddl} arm is uninhabited.

    The pipeline grammar enforces structurally that a sink terminates a pipeline
    -- a query operator after [| insert into ...] is a parse error. A leading
    [:] is no longer recognised: every DDL statement has been retired in favour
    of pipe-form operators, so [:list tables] and friends are now plain parse
    errors.

    Leading and trailing whitespace are accepted; the parser must consume the
    entire input. *)

val parse_row_type : string -> (Ast.type_expression, error) result
(** [parse_row_type input] parses [input] as a surface row-type expression: a
    parenthesised, comma-separated list of [name: kind] bindings, with a
    permitted trailing comma. The empty form [()] is accepted. Refinement
    clauses (e.g. [primary key (...)]) are rejected — those belong to a relation
    type, parsed by {!parse_relation_type}.

    Leading and trailing whitespace are accepted; the parser must consume the
    entire input. Not yet wired into the pipeline grammar; exposed for direct
    testing while the new literal syntax is being assembled. *)

val parse_relation_type : string -> (Ast.type_expression, error) result
(** [parse_relation_type input] parses [input] as a surface relation-type
    expression: the row-type form (see {!parse_row_type}) followed by zero or
    more refinement clauses, all in the same parenthesised list. The only
    refinement available today is [primary key (col, col, ...)]; new refinements
    slot in as additional clause keywords.

    Leading and trailing whitespace are accepted; the parser must consume the
    entire input. Not yet wired into the pipeline grammar; exposed for direct
    testing while the new literal syntax is being assembled. *)

val parse_expression : string -> (Expression.t, error) result
(** [parse_expression input] parses [input] as a single expression in the
    sublanguage shared by [restrict] and [join ... on]. The grammar, from
    loosest to tightest binding:

    - [or] — left-associative, lowest precedence.
    - [and] — left-associative.
    - [not] — prefix unary; stacks ([not not active] parses).
    - Comparisons [=], [<>], [<], [<=], [>], [>=] — non-associative.
    - Atoms: literals, column references, or a parenthesised expression.

    Atoms are:

    - signed int64 literals ([-1], [0], [42]);
    - double-quoted string literals (backslash-quote and backslash-backslash are
      the only recognised escapes);
    - [true] / [false];
    - column references, bare ([name]) or qualified ([users.name]) with no
      whitespace around the dot.

    A standalone atom is a valid expression at the parser level; whether it
    resolves to a [Bool] (and so is acceptable in a predicate position) is a
    resolve-time concern handled by {!Expression.resolve}.

    Leading and trailing whitespace are accepted; the parser must consume the
    entire input. *)
