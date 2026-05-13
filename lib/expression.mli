(** Expression tree used in predicate positions across the IRs.

    An [Expression.t] is an algebraic expression that produces a {!Value.t} when
    evaluated against a {!Schema.tuple}: a literal, a column reference, or a
    comparison of two sub-expressions. Both {!Logical.Restrict} and
    {!Physical.Filter} carry an [Expression.t]; the expression refers to columns
    by name so it stays human-readable for debugging and EXPLAIN-style
    introspection. Mapping names to tuple positions is an executor concern,
    handled by {!resolve}.

    "Predicate" is the role an expression plays at the top of a
    {!Logical.Restrict} or {!Physical.Filter}: it must resolve to a value of
    kind {!Value.Kind.Bool}. {!resolve} enforces that.

    Slice 4 step 3 introduced {!Schema.column_reference} for column nodes so the
    qualifier (set when a cross product or join exposes same-named columns from
    different inputs) is carried end to end. Slice 7 step 2 generalised the IR
    from a single comparison to the tree below. Boolean composition
    (and/or/not), ordering comparisons, and parens arrive in later slice-7
    steps. *)

(** Comparison operator.

    {!Equal} and {!NotEqual} apply to any pair of operands whose kinds agree;
    the four ordering operators are defined only for kinds with a meaningful
    order -- {!Value.Kind.Int64} (numeric) and {!Value.Kind.String}
    (lexicographic by byte). Applying an ordering operator to {!Value.Kind.Bool}
    operands is rejected at resolve time. *)
type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

(** An expression node. *)
type t =
  | Literal of Value.t  (** A constant value. *)
  | Column of Schema.column_reference
      (** A reference to a column in the surrounding schema. The qualifier is
          set when the schema exposes same-named columns from different inputs.
      *)
  | Compare of { left : t; op : comparison_op; right : t }
      (** A comparison of two sub-expressions. The two sides' kinds must agree
          at resolve time; the comparison's own kind is {!Value.Kind.Bool}. *)

val format : Format.formatter -> t -> unit
(** [format formatter expression] writes a single-line, source-like rendering of
    [expression] to [formatter]. Column references render in the dotted form
    when qualified ([users.id]) and bare otherwise; string literals are
    double-quoted (no escape handling); comparisons render as [left <op> right].
    The output is meant for EXPLAIN-style debug printing, not for round-tripping
    back through the parser. *)

val resolve : Schema.t -> t -> Schema.tuple -> bool
(** [resolve schema expression] validates [expression] against [schema] and
    returns a closure that evaluates [expression] against a single tuple as a
    boolean predicate.

    Validation, performed once at resolve time:

    - Every {!Column} sub-expression must resolve uniquely against [schema] -- a
      qualified reference must match exactly one field; an unqualified one must
      match exactly one field by name.
    - Each {!Compare}'s left and right sub-expressions must agree on
      {!Value.Kind.t}.
    - Ordering operators ({!Less}, {!LessEqual}, {!Greater}, {!GreaterEqual})
      require the kind to be ordered: {!Value.Kind.Int64} or
      {!Value.Kind.String}.
    - The whole expression's kind must be {!Value.Kind.Bool}. Predicate
      positions accept only Bool-valued expressions, so a standalone {!Column}
      of kind {!Value.Kind.Bool} is a valid predicate ([restrict active]), while
      a standalone {!Column} of any other kind is rejected.

    The closure does a constant number of array indices and structural
    comparisons per call. Each {!Column}'s field-order position is captured at
    resolve time, so no name lookup happens per row.

    Raises [Failure] if a column reference is unknown or ambiguous, two sides of
    a {!Compare} disagree on kind, an ordering operator is applied to a
    non-ordered kind, or the top-level expression does not have
    {!Value.Kind.Bool}. *)
