(** Projection sublanguage shared across the IRs.

    A projection is an ordered list of column names to keep from the input
    relation. Both {!Logical.Project} and {!Physical.Project} carry a
    [Projection.t]; columns are referred to by name so the IR stays
    human-readable for debugging. Mapping names to tuple positions is an
    executor concern, handled by {!resolve}.

    Slice 3 ships only bare column names. Expressions, aliases, and qualified
    references arrive in later slices. *)

type t = string list
(** The ordered list of column names to project. Order is preserved in the
    output schema and tuples. *)

val resolve : Schema.t -> t -> Schema.t * (Schema.tuple -> Schema.tuple)
(** [resolve input_schema columns] validates [columns] against [input_schema]
    and returns the projected schema together with a closure that builds the
    projected tuple.

    Validation, performed once at resolve time:

    - Every column in [columns] must exist in [input_schema].
    - No column may appear more than once in [columns].

    The returned schema has its [fields] in the order requested by [columns],
    each field carrying the kind it had in [input_schema]. The [primary_key] of
    the returned schema is always [[]]: derived relations don't carry
    primary-key information at this stage of the project, even when the
    projected columns happen to include the input's primary key.

    Each column's field-order position in the input schema is captured at
    resolve time, so the per-tuple closure does only [List.length columns] array
    indexes -- no name lookup happens per row.

    Raises [Failure] if a named column is unknown to [input_schema], or if a
    column name appears more than once in [columns]. *)
