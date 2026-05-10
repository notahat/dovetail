(** Parser for the relational-algebra query language.

    Built on [angstrom]. Slice 1's grammar is one production: a bare identifier
    parses to {!Ast.Relation_name}. Whitespace surrounding the identifier is
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

val parse : string -> (Ast.t, error) result
(** [parse input] parses [input] as a complete query. Leading and trailing
    whitespace are accepted; the parser must consume the entire input. *)
