(** Parser for the relational-algebra query language.

    Built on [angstrom]. The grammar is a base relation reference followed by
    zero or more pipe-separated steps: [restrict <predicate>],
    [project <columns>], [cross <relation>], and
    [join <relation> on <predicate>]. Whitespace surrounding tokens is
    tolerated; anything else (extra tokens, malformed identifiers, empty input)
    is rejected.

    The error type is currently a string passed straight from angstrom. When a
    later slice produces user-visible errors with location information or
    structured cases, this becomes a proper variant; the {!type-error} alias
    exists now so callers can already speak in terms of [Parser.error] rather
    than coupling to [string]. *)

type error = string
(** Slice-1 placeholder for parser errors. The string is whatever angstrom
    produced. *)

val parse : string -> (Ast.plan, error) result
(** [parse input] parses [input] as a complete top-level pipeline. The result is
    an {!Ast.plan} — an {!Ast.Query} for any pipeline without a sink, or an
    {!Ast.Mutation} for a pipeline whose final step is a sink (today, only
    [| insert into <table>]). The wrapper enforces in the grammar that a sink
    terminates a pipeline: a query operator after a sink is a parse error.

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
