(** Canonical-form printer for DDL statements.

    The inverse of the DDL parser: for every {!Statement.t} value [s],
    [Parser.parse (statement s)] parses back to a wrapper around the same [s]
    (the round-trip property pinned by the test corpus). Today's only statement
    [:list tables] prints as a single line with no trailing newline. *)

val statement : Statement.t -> string
(** [statement s] formats [s] in canonical form. *)
