(** The physical [Type_op] operator.

    Reports the static kind of its input as a [Term.*_kind] value, without
    pulling any rows. Out of scope: evaluating the input for its rows — this
    operator only ever inspects shape. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  input:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction ~input continue] computes [input]'s static
    kind and hands [continue] the matching [Term.*_kind] arm. Scalar, row, and
    catalog inputs short-circuit to their own per-rung kind; every other shape
    is a relation, whose kind comes from [Plan.Physical.kind_of]. No cursors are
    opened. A missing-table reference inside [input] surfaces with the same
    wording the relational cases produce at scan time. *)
