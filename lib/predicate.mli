(** Predicate sublanguage shared across the IRs.

    A predicate is a single comparison of a column against a literal. Both
    {!Logical.Select} and {!Physical.Filter} carry a [Predicate.t]; the
    predicate refers to columns by name so it stays human-readable for debugging
    and EXPLAIN-style introspection. Mapping names to tuple positions is an
    executor concern, handled by {!resolve}.

    Slice 2 ships only [Compare] with equality and inequality. Boolean
    composition (and/or/not), parens, and ordering operators arrive in later
    slices. *)

(** Comparison operator. *)
type op = Equal | NotEqual

(** A predicate. The single-constructor form leaves room for boolean composition
    without changing call sites that already pattern-match. *)
type t = Compare of { column_name : string; op : op; literal : Value.t }

val resolve : Schema.t -> t -> Schema.tuple -> bool
(** [resolve schema predicate] validates [predicate] against [schema] and
    returns a closure that evaluates [predicate] against a single tuple.

    Validation, performed once at resolve time:

    - The named column must exist in [schema].
    - Its {!Value.Kind.t} must match the literal's runtime type.

    The closure does only an array index and a structural comparison per call.
    The column's field-order position is captured at resolve time, so no name
    lookup happens per row.

    Raises [Failure] if the column is unknown to the schema, or if the column's
    kind does not match the literal's type. *)
