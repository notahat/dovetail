(** Projection sublanguage shared across the IRs.

    A projection is an ordered list of column references to keep from the input
    relation. Both {!Logical.Project} and {!Physical.Project} carry a
    [Projection.t]; columns are referred to by name (and optional qualifier) so
    the IR stays human-readable for debugging. Mapping references to row
    positions is an executor concern, handled by {!resolve}. *)

module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

type t = Row.column_reference list
(** The ordered list of column references to project. Order is preserved in the
    output row kind and rows. *)

val format : Format.formatter -> t -> unit
(** [format formatter projection] writes [projection] as a comma-separated list
    of column references in their source-like form (bare [name] or qualified
    [qualifier.name]). The empty projection renders as the empty string.
    Intended for EXPLAIN-style debug printing -- {!Physical.format} renders a
    [Project] operator's [columns] parameter through this function. *)

val resolve : Relation.kind -> t -> Relation.kind * (Row.value -> Row.value)
(** [resolve input_kind columns] validates [columns] against [input_kind] and
    returns the projected {!Relation.kind} together with a closure that builds
    the projected row.

    Validation, performed once at resolve time:

    - Every column reference in [columns] must resolve uniquely against
      [input_kind].
    - No column reference (in its source form -- bare or dotted) may appear more
      than once in [columns].

    The returned kind has its [row_kind] in the order requested by [columns],
    each field carrying the kind and qualifier it had in [input_kind]. The
    returned kind carries no refinements: derived relations don't carry primary-
    key information at this stage of the project, even when the projected
    columns happen to include the input's primary key.

    Each column's field-order position in the input row kind is captured at
    resolve time, so the per-row closure does only [List.length columns] array
    indexes -- no name lookup happens per row.

    Raises [Failure] if a column reference is unknown or ambiguous against
    [input_kind], or if the same reference appears more than once. *)
