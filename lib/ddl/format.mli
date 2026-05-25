(** Canonical-form printer for DDL statements.

    The inverse of the DDL parser: for every {!Statement.t} value [s],
    [Parser.parse (statement s)] parses back to a wrapper around the same [s]
    (the round-trip property pinned by the test corpus). Today's two surface
    forms ([:list tables] and [:drop table <name>]) both print as a single line,
    with no embedded newlines and no trailing newline -- callers add one when
    they need it. *)

val statement : Statement.t -> string
(** [statement s] formats [s] in canonical form. See the module-level
    documentation for the exact shape. *)
