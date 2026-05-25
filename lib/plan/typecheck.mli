(** Single home for the kind-discipline and column-resolution checks a query
    must pass before {!Translate} and {!Eval} run.

    {!typecheck} walks a {!Logical.t} against a snapshotted {!Catalog.kind} and
    accumulates every error it finds, so one walk reports every problem rather
    than just the first. Today the pass is a no-op; checks migrate in from
    {!Translate}, {!Eval}, and {!Surface_ra.Lower} step by step, with one error
    constructor per check.

    The success arm returns the input {!Logical.t} unchanged. The shape stays
    the same once a typed Logical IR replaces the untyped one in a later slice —
    the success arm widens to that type then. *)

module Catalog = Dovetail_core.Catalog
module Expression = Dovetail_core.Expression
module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar

(** Coarse classification of what a [Logical.t] subtree yields. Used by the
    operator-shape preconditions ({!Tables_input_wrong_rung},
    {!Unqualify_input_wrong_rung}) to describe what kind of value an operator's
    input actually has when it has the wrong one. *)
type rung = Scalar | Row | Relation | Catalog | Kind

(** The variant of user-facing typecheck errors. Each constructor carries the
    structured detail an LSP needs; {!render} produces the user-facing string.
*)
type error =
  | Insert_column_mismatch of {
      table_name : string;
      missing : string list;
      extra : string list;
    }
      (** The source of an [Insert] has a different column set than the target
          table. [missing] names the target's columns absent from the source, in
          target row-order; [extra] names the source's columns absent from the
          target, in source row-order. At least one of the two is non-empty. *)
  | Insert_kind_mismatch of {
      table_name : string;
      column : string;
      expected : Scalar.kind;
      actual : Scalar.kind;
    }
      (** A column of an [Insert]'s source has a scalar kind different from the
          target column with the same name. One error per mismatching column;
          emitted in source row-order. Only fires once [Insert_column_mismatch]
          has not, so [column] is guaranteed to name a column present in both
          source and target. *)
  | Unresolved_column of {
      column_reference : Row.column_reference;
      available_row_kind : Row.kind;
      operator : string;
    }
      (** A column reference in an operator's expression or projection does not
          resolve to exactly one field of the operator's input row kind. Covers
          both unknown columns (no match) and ambiguous bare references (more
          than one match across qualifiers); the renderer distinguishes them
          from [column_reference] against [available_row_kind]. [operator] names
          the user-facing operator the reference appears in (for example
          ["Restrict"], ["Project"]); the renderer uses it as the error prefix.
      *)
  | Compare_kind_mismatch of {
      operator : string;
      left : Expression.t;
      left_kind : Scalar.kind;
      right : Expression.t;
      right_kind : Scalar.kind;
    }
      (** The two operands of a [Compare] inside an expression disagree on
          scalar kind. [operator] names the user-facing operator the expression
          appears in (for example ["Restrict"]); [left] / [right] are the
          operand sub-expressions, included so the renderer can describe them in
          the same source-flavoured wording the legacy resolve-time message
          uses. *)
  | Boolean_operand_required of {
      operator : string;
      logical_op : string;
      operand : Expression.t;
      operand_kind : Scalar.kind;
    }
      (** An [And], [Or], or [Not] node carries an operand whose scalar kind is
          not [Bool]. [operator] names the user-facing operator the expression
          appears in (for example ["Restrict"]) and becomes the renderer's
          prefix; [logical_op] is the source word for the offending node
          (["and"], ["or"], or ["not"]) so the renderer can echo it back.
          [operand] is the offending sub-expression, included so the renderer
          can describe it in the source-flavoured wording the legacy
          resolve-time message used. *)
  | Predicate_not_boolean of {
      operator : string;
      expression : Expression.t;
      actual_kind : Scalar.kind;
    }
      (** The top expression in a predicate position (today: a [Restrict]'s
          predicate) has a scalar kind other than [Bool]. [operator] names the
          user-facing operator the predicate belongs to and becomes the
          renderer's prefix; [expression] is the whole offending predicate (kept
          for LSP detail even though the renderer does not name it, matching the
          legacy resolve-time message). *)
  | Unknown_table of { operator : string; table_name : string }
      (** A query refers to a table that does not exist in the catalog snapshot.
          [operator] names the user-facing operator the reference appears in
          ([{"Scan"}] for a source table, [{"Insert"}] for an insert target) and
          becomes the renderer's prefix; [table_name] is the missing table's
          name. *)
  | Projection_duplicate_column of {
      operator : string;
      column_reference : Row.column_reference;
    }
      (** A [Project]'s column list names the same column twice. [operator]
          names the user-facing operator (today: always ["Project"]) and becomes
          the renderer's prefix; [column_reference] carries the duplicated
          reference for the renderer to echo back. Emitted once per duplicate
          occurrence beyond the first, so a column listed three times produces
          two errors. *)
  | Relation_literal_kind_mismatch of {
      row_index : int;
      column : string;
      expected : Scalar.kind;
      actual : Scalar.kind;
    }
      (** A cell in a [Relation_literal] row has a scalar kind different from
          the declared kind's column at the same position. [row_index] is the
          row's zero-based index in source order; [column] is the column name
          taken from the declared kind. One error per mismatching cell. Lower
          still raises on name-mismatch and missing-/extra-field structural
          problems before this check fires, so [column] always names a real
          declared column. *)
  | Tables_input_wrong_rung of { actual : rung }
      (** A [Tables] operator's input is not a catalog. [actual] is the
          best-effort rung classification of the input subtree. The renderer
          turns it into [Tables: expected a catalog input, got <actual>]. *)
  | Unqualify_input_wrong_rung of { actual : rung }
      (** An [Unqualify] operator's input is neither a relation nor a row.
          [actual] is the best-effort rung classification of the input subtree.
          The renderer turns it into
          [Unqualify: expected a relation or row input, got <actual>]. *)
  | Ordering_operator_on_unordered_kind of {
      operator : string;
      comparison_op : Expression.comparison_op;
      kind : Scalar.kind;
    }
      (** A comparison expression uses an ordering operator ([<], [<=], [>],
          [>=]) on a kind without a meaningful order. Today the only unordered
          scalar kind is [Bool]; [kind] carries the operands' shared kind so the
          renderer can name it. Emitted only when the operands' kinds already
          agree, so [Compare_kind_mismatch] never overlaps with this error on
          the same node. *)

val render : error -> string
(** [render error] formats [error] for a human reader, with an operator-named
    prefix matching what the user wrote (for example [Insert: ...],
    [Restrict: ...]). *)

val typecheck :
  catalog:Catalog.kind -> Logical.t -> (Logical.t, error list) result
(** [typecheck ~catalog plan] checks [plan] against [catalog] and returns it
    unchanged on success, or an accumulated list of every error found. [catalog]
    is a snapshot taken inside the read transaction the caller will later use
    for execution, so the catalog kinds the pass validates against can't shift
    before evaluation. *)
