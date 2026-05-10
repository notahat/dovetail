(** Projection sublanguage shared across the IRs.

    A projection is an ordered list of column references to keep from the input
    relation. Both {!Logical.Project} and {!Physical.Project} carry a
    [Projection.t]; columns are referred to by name (and optional qualifier) so
    the IR stays human-readable for debugging. Mapping references to tuple
    positions is an executor concern, handled by {!resolve}.

    Slice 4 step 3 generalises the per-column representation from a bare string
    to {!Schema.column_reference} so qualified-column refs flow from parser
    through IR to executor. Expressions and aliases arrive in later slices. *)

type t = Schema.column_reference list
(** The ordered list of column references to project. Order is preserved in the
    output schema and tuples. *)

val resolve : Schema.t -> t -> Schema.t * (Schema.tuple -> Schema.tuple)
(** [resolve input_schema columns] validates [columns] against [input_schema]
    and returns the projected schema together with a closure that builds the
    projected tuple.

    Validation, performed once at resolve time:

    - Every column reference in [columns] must resolve uniquely against
      [input_schema].
    - No column reference (in its source form -- bare or dotted) may appear more
      than once in [columns].

    The returned schema has its [fields] in the order requested by [columns],
    each field carrying the kind and qualifier it had in [input_schema]. The
    [primary_key] of the returned schema is always [[]]: derived relations don't
    carry primary-key information at this stage of the project, even when the
    projected columns happen to include the input's primary key.

    Each column's field-order position in the input schema is captured at
    resolve time, so the per-tuple closure does only [List.length columns] array
    indexes -- no name lookup happens per row.

    Raises [Failure] if a column reference is unknown or ambiguous against
    [input_schema], or if the same reference appears more than once. *)
