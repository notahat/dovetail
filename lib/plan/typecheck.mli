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
module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar

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
