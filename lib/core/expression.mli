(** Expression tree used in predicate positions across the IRs.

    An [Expression.t] is an algebraic expression that produces a {!Scalar.value}
    when evaluated against a {!Row.value}. The tree's leaves are literals and
    column references; its internal nodes are comparisons and boolean
    composition ([and], [or], [not]). Column references carry a
    {!Row.column_reference} so a qualifier (set when a cross product or join
    exposes same-named columns from different inputs) is preserved end to end.

    Both {!Logical.Restrict} and {!Physical.Filter} carry an [Expression.t];
    expressions refer to columns by name so they stay human-readable for
    debugging and EXPLAIN-style introspection. Mapping names to row positions is
    an executor concern, handled by {!resolve}.

    "Predicate" is the role an expression plays at the top of a
    {!Logical.Restrict} or {!Physical.Filter}: it must resolve to a value of
    kind {!Scalar.Bool}. {!resolve} enforces that, so a standalone [Bool]-kinded
    column or literal is a valid predicate ([restrict active]) while a
    non-[Bool] expression at that position is rejected. *)

(** Comparison operator.

    {!Equal} and {!NotEqual} apply to any pair of operands whose kinds agree;
    the four ordering operators are defined only for kinds with a meaningful
    order -- {!Scalar.Int64} (numeric) and {!Scalar.String} (lexicographic by
    byte). Applying an ordering operator to {!Scalar.Bool} operands is rejected
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
  | Literal of Scalar.value  (** A constant value. *)
  | Column of Row.column_reference
      (** A reference to a column in the surrounding row kind. The qualifier is
          set when the schema exposes same-named columns from different inputs.
      *)
  | Compare of { left : t; op : comparison_op; right : t }
      (** A comparison of two sub-expressions. The two sides' kinds must agree
          at resolve time; the comparison's own kind is {!Scalar.Bool}. *)
  | And of t * t
      (** Boolean conjunction of two sub-expressions. Both operands must be of
          kind {!Scalar.Bool}. The resolver evaluates left-to-right and
          short-circuits: the right operand is only read when the left is true.
      *)
  | Or of t * t
      (** Boolean disjunction of two sub-expressions. Both operands must be of
          kind {!Scalar.Bool}. The resolver short-circuits the same way: the
          right operand is only read when the left is false. *)
  | Not of t
      (** Boolean negation of a sub-expression. The operand must be of kind
          {!Scalar.Bool}. *)

val format : Format.formatter -> t -> unit
(** [format formatter expression] writes a single-line, source-like rendering of
    [expression] to [formatter]. Column references render in the dotted form
    when qualified ([users.id]) and bare otherwise; string literals are
    double-quoted (no escape handling); comparisons render as [left <op> right].
    The output is meant for EXPLAIN-style debug printing, not for round-tripping
    back through the parser. *)

val resolve : Row.kind -> t -> Row.value -> bool
(** [resolve row_kind expression] returns a closure that evaluates [expression]
    against a single row as a boolean predicate.

    {!Plan.Typecheck} is the home for kind discipline and column resolution;
    callers are expected to have run it. [resolve] does no validation of its own
    -- it walks [expression] once, looks each [Column] up against [row_kind],
    and assembles operator closures. The closure does a constant number of array
    indices and structural comparisons per call.

    Pre: [expression] has been validated by {!Plan.Typecheck} against
    [row_kind]. Every column resolves uniquely, every {!Compare}'s operands
    agree on kind (and ordering operators only see ordered kinds), every {!And}
    / {!Or} / {!Not} operand is {!Scalar.Bool}, and the whole expression is
    {!Scalar.Bool}. Violations are caught earlier; the closure may
    [assert false] if they reach it. *)
