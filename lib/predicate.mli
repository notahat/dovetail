(** Predicate sublanguage shared across the IRs.

    A predicate is a single comparison of two terms, where each term is either a
    column reference or a literal. Both {!Logical.Restrict} and
    {!Physical.Filter} carry a [Predicate.t]; the predicate refers to columns by
    name so it stays human-readable for debugging and EXPLAIN-style
    introspection. Mapping names to tuple positions is an executor concern,
    handled by {!resolve}.

    Slice 4 step 3 reuses {!Schema.column_reference} for column terms so the
    qualifier (set when a cross product or join exposes same-named columns from
    different inputs) is carried end to end. Boolean composition (and/or/not),
    parens, and ordering operators arrive in later slices. *)

(** Comparison operator. *)
type op = Equal | NotEqual

(** A single side of a comparison: either a column reference (bare or qualified)
    or a literal value. *)
type term = Column of Schema.column_reference | Literal of Value.t

(** A predicate. The single-constructor form leaves room for boolean composition
    without changing call sites that already pattern-match. *)
type t = Compare of { left : term; op : op; right : term }

val resolve : Schema.t -> t -> Schema.tuple -> bool
(** [resolve schema predicate] validates [predicate] against [schema] and
    returns a closure that evaluates [predicate] against a single tuple.

    Validation, performed once at resolve time:

    - Every {!Column} term must resolve uniquely against [schema] -- a qualified
      reference must match exactly one field; an unqualified one must match
      exactly one field by name.
    - The two sides' {!Value.Kind.t}s must agree.

    The closure does at most two array indices and a structural comparison per
    call. Each {!Column} term's field-order position is captured at resolve
    time, so no name lookup happens per row.

    Raises [Failure] if a column reference is unknown or ambiguous, or if the
    two sides' kinds disagree. *)
