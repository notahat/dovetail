(** Canonical-form printer for DDL statements.

    The inverse of the DDL parser: for every {!Statement.t} value [s],
    [Parser.parse (statement s)] parses back to a wrapper around the same [s]
    (the round-trip property pinned by the test corpus). The two one-liner
    statements ([:list tables], [:drop table <name>]) print as a single line;
    [:create table <name> ...] prints in the design doc's canonical multi-line
    form with one column per indented line, a trailing comma on every column
    line (including the last), and the [primary key (...)] clause on its own
    closing line.

    Output strings carry embedded newlines for the multi-line form but do not
    end with a trailing newline -- callers add one when they need it. *)

val statement : Statement.t -> string
(** [statement s] formats [s] in canonical form. See the module-level
    documentation for the exact shape; the design doc's [users] and
    [order_items] examples in [docs/plans/ddl-design.md] are the canonical
    reference for the multi-line form. *)
