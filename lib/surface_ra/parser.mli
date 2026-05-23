(** Parser for the relational-algebra query language.

    Built on [angstrom]. A top-level input is one of two universes, decided by
    the first non-whitespace character: a leading [:] introduces a DDL statement
    ([:list tables], [:drop table <name>], [:describe <name>],
    [:create table ...]); anything else is a relational pipeline -- a base
    relation reference followed by zero or more pipe-separated steps:
    [restrict <predicate>], [project <columns>], [cross <relation>],
    [join <relation> on <predicate>], and optionally a terminal sink
    ([insert into <table>]). Whitespace surrounding tokens is tolerated;
    anything else (extra tokens, malformed identifiers, empty input, a [:]
    mid-pipeline) is rejected.

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
    an {!Ast.program}: either an {!Ast.Pipeline} carrying an {!Ast.t} (a
    relational pipeline; [Ast.Insert] sits inside [t] as a regular operator) or
    an {!Ast.Ddl} carrying a {!Statement.t} (a data-definition statement
    introduced by the leading [:] sigil).

    The pipeline grammar enforces structurally that a sink terminates a pipeline
    -- a query operator after [| insert into ...] is a parse error. The [:]
    sigil is recognised only at the very top of the input, so a [:] inside a
    pipeline or expression is a parse error rather than a DDL statement.

    Leading and trailing whitespace are accepted; the parser must consume the
    entire input. *)

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
