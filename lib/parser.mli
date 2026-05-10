(** Parser for the relational-algebra query language.

    Built on [angstrom]. Slice 1's grammar is one production: a bare identifier
    parses to {!Ast.Relation_name}. Slice 2 adds [restrict] pipeline steps;
    slice 3 adds [project] pipeline steps with a comma-separated column list.
    Whitespace surrounding tokens is tolerated; anything else (extra tokens,
    malformed identifiers, empty input) is rejected.

    The error type is currently a string passed straight from angstrom. When a
    later slice produces user-visible errors with location information or
    structured cases, this becomes a proper variant; the {!type-error} alias
    exists now so callers can already speak in terms of [Parser.error] rather
    than coupling to [string]. *)

type error = string
(** Slice-1 placeholder for parser errors. The string is whatever angstrom
    produced. *)

val parse : string -> (Ast.t, error) result
(** [parse input] parses [input] as a complete query. Leading and trailing
    whitespace are accepted; the parser must consume the entire input. *)

val parse_predicate : string -> (Predicate.t, error) result
(** [parse_predicate input] parses [input] as a single predicate of the form
    [<term> <op> <term>], with [op] one of [=] or [<>] and each term either a
    column reference (a bare identifier) or a literal:

    - signed int64 ([-1], [0], [42])
    - double-quoted string; backslash-quote and backslash-backslash are the only
      recognised escape sequences
    - [true] / [false]

    Either side can be a column reference, so column-vs-literal,
    literal-vs-column, and column-vs-column all parse. Leading and trailing
    whitespace are accepted; the parser must consume the entire input. *)
