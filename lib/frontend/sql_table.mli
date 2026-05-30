(** PostgreSQL-style result table for the SQL surface.

    Renders a query result as the aligned text table a psql user expects:
    centred column headers over a dashed rule, then one line per row, with a
    trailing row count. This is a presentation policy of the SQL surface, not a
    canonical value form -- unlike {!Dovetail_core.Relation.format}, the output
    does not round-trip as input. It lives in [frontend] for that reason: it is
    how the SQL REPL chooses to show results, and the RA surface keeps the
    relation-literal form instead.

    Cell rendering deliberately diverges from {!Dovetail_core.Scalar.format}:
    strings appear bare (no surrounding quotes) so the table reads as data
    rather than source. Booleans render as [true]/[false] -- this project's
    scalar spelling -- rather than psql's [t]/[f]. *)

val format : Format.formatter -> _ Dovetail_core.Relation.t -> unit
(** [format formatter relation] writes [relation] as a psql-style table.

    The header line centres each column's bare field name (any qualifier is
    stripped -- safe while results are single-table, since no two columns can
    then collide on their bare name) over a column whose width is the wider of
    the header and the widest cell. A dashed rule ([---+---]) separates the
    header from the rows. Int64 cells are right-aligned; string and bool cells
    are left-aligned. Every cell is surrounded by a single space inside the [|]
    separators, so left-padded and short cells carry trailing spaces, matching
    psql. A trailing [(N rows)] count closes the table, with [(1 row)] in the
    singular and [(0 rows)] for an empty relation -- whose header and rule are
    still emitted.

    Materialises the relation's [value] sequence eagerly to measure column
    widths. No trailing newline is emitted after the footer, matching the other
    [format] functions in the codebase; the REPL adds the cut. *)
