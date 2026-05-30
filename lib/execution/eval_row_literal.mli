(** The physical [Row_literal] operator.

    Materialises a single row from a list of named values, deriving its kind
    from the values' scalar kinds. Also exposes that kind derivation on its own,
    since the [type] operator needs a row literal's kind without materialising
    the row. Out of scope: multi-row literals — those are [Relation_literal]. *)

module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term

val kind_of_fields : (Row.column_reference * Scalar.value) list -> Row.kind
(** [kind_of_fields fields] builds a [Row.kind] from a row literal's
    [(reference, value)] pairs by reading each value's scalar kind. The
    qualifier on each reference rides through unchanged, so [(id = 1)] yields a
    field with [qualifier = None] and [(users.id = 1)] yields one with
    [qualifier = Some "users"]. *)

val evaluate :
  (Row.column_reference * Scalar.value) list -> (_ Term.t -> 'a) -> 'a
(** [evaluate fields continue] hands [continue] a [Term.Row_value] whose kind is
    derived eagerly from the values' scalar kinds. No storage is touched. *)
