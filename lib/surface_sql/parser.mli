(** Parser for the SQL query language.

    Built on [angstrom]. A top-level input is a single SQL statement; today the
    only statement is [SELECT * FROM <table>], with an optional trailing
    semicolon. Keywords ([SELECT], [FROM]) are case-insensitive; identifiers are
    matched case-sensitively against the catalog. Whitespace surrounding tokens
    is tolerated; anything else (extra tokens after the statement, a malformed
    identifier, empty input) is rejected.

    The error type is a string passed straight from angstrom, mirroring the
    relational-algebra surface's parser. When user-visible errors gain location
    information or structured cases this becomes a proper variant; the
    {!type-error} alias exists now so callers speak in terms of [Parser.error]
    rather than coupling to [string]. *)

type error = string
(** Placeholder for parser errors. The string is whatever angstrom produced. *)

val parse : string -> (Ast.t, error) result
(** [parse input] parses [input] as a complete SQL statement. A single trailing
    semicolon is accepted; trailing junk after it is a parse error. Leading and
    trailing whitespace are accepted; the parser must consume the entire input.
*)
