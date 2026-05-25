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
(** [resolve input_kind columns] returns the projected {!Relation.kind} together
    with a closure that builds the projected row.

    {!Plan.Typecheck} is the home for column resolution and duplicate-column
    detection; callers are expected to have run it. [resolve] does no validation
    of its own -- it looks each reference up against [input_kind.row_kind] and
    captures the field-order position so the per-row closure does only
    [List.length columns] array indexes.

    The returned kind has its [row_kind] in the order requested by [columns],
    each field carrying the kind and qualifier it had in [input_kind]. The
    returned kind carries no refinements: derived relations don't carry primary-
    key information at this stage of the project, even when the projected
    columns happen to include the input's primary key.

    Pre: [columns] has been validated by {!Plan.Typecheck} against [input_kind].
    Every reference resolves uniquely and no reference is duplicated. Violations
    are caught earlier; the closure may [assert false] if they reach it. *)
