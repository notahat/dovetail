(** Expression tree used in predicate positions across the IRs.

    An [Expression.t] is an algebraic expression that produces a {!Value.data}
    when evaluated against a {!Row.data}. The tree's leaves are literals and
    column references; its internal nodes are comparisons and boolean
    composition ([and], [or], [not]). Column references carry a
    {!Row.column_reference} so a qualifier (set when a cross product or join
    exposes same-named columns from different inputs) is preserved end to end.

    Both {!Logical.Restrict} and {!Physical.Filter} carry an [Expression.t];
    expressions refer to columns by name so they stay human-readable for
    debugging and EXPLAIN-style introspection. Mapping names to tuple positions
    is an executor concern, handled by {!resolve}.

    "Predicate" is the role an expression plays at the top of a
    {!Logical.Restrict} or {!Physical.Filter}: it must resolve to a value of
    kind {!Value.Bool}. {!resolve} enforces that, so a standalone [Bool]-kinded
    column or literal is a valid predicate ([restrict active]) while a
    non-[Bool] expression at that position is rejected. *)

(** Comparison operator.

    {!Equal} and {!NotEqual} apply to any pair of operands whose kinds agree;
    the four ordering operators are defined only for kinds with a meaningful
    order -- {!Value.Int64} (numeric) and {!Value.String} (lexicographic by
    byte). Applying an ordering operator to {!Value.Bool} operands is rejected
    at resolve time. *)
type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

(** An expression node. *)
type t =
  | Literal of Value.data  (** A constant value. *)
  | Column of Row.column_reference
      (** A reference to a column in the surrounding row kind. The qualifier is
          set when the schema exposes same-named columns from different inputs.
      *)
  | Compare of { left : t; op : comparison_op; right : t }
      (** A comparison of two sub-expressions. The two sides' kinds must agree
          at resolve time; the comparison's own kind is {!Value.Bool}. *)
  | And of t * t
      (** Boolean conjunction of two sub-expressions. Both operands must be of
          kind {!Value.Bool}. The resolver evaluates left-to-right and
          short-circuits: the right operand is only read when the left is true.
      *)
  | Or of t * t
      (** Boolean disjunction of two sub-expressions. Both operands must be of
          kind {!Value.Bool}. The resolver short-circuits the same way: the
          right operand is only read when the left is false. *)
  | Not of t
      (** Boolean negation of a sub-expression. The operand must be of kind
          {!Value.Bool}. *)

val format : Format.formatter -> t -> unit
(** [format formatter expression] writes a single-line, source-like rendering of
    [expression] to [formatter]. Column references render in the dotted form
    when qualified ([users.id]) and bare otherwise; string literals are
    double-quoted (no escape handling); comparisons render as [left <op> right].
    The output is meant for EXPLAIN-style debug printing, not for round-tripping
    back through the parser. *)

val resolve : Row.kind -> t -> Row.data -> bool
(** [resolve row_kind expression] validates [expression] against [row_kind] and
    returns a closure that evaluates [expression] against a single row as a
    boolean predicate.

    Validation, performed once at resolve time:

    - Every {!Column} sub-expression must resolve uniquely against [row_kind] --
      a qualified reference must match exactly one field; an unqualified one
      must match exactly one field by name.
    - Each {!Compare}'s left and right sub-expressions must agree on
      {!Value.kind}.
    - Ordering operators ({!Less}, {!LessEqual}, {!Greater}, {!GreaterEqual})
      require the kind to be ordered: {!Value.Int64} or {!Value.String}.
    - Both operands of an {!And} or {!Or}, and the operand of a {!Not}, must
      have kind {!Value.Bool}.
    - The whole expression's kind must be {!Value.Bool}. Predicate positions
      accept only Bool-valued expressions, so a standalone {!Column} of kind
      {!Value.Bool} is a valid predicate ([restrict active]), while a standalone
      {!Column} of any other kind is rejected.

    The closure does a constant number of array indices and structural
    comparisons per call. Each {!Column}'s field-order position is captured at
    resolve time, so no name lookup happens per row.

    Raises [Failure] if a column reference is unknown or ambiguous, two sides of
    a {!Compare} disagree on kind, an ordering operator is applied to a
    non-ordered kind, an {!And} / {!Or} / {!Not} has a non-Bool operand, or the
    top-level expression does not have {!Value.Bool}. *)
