(** The physical [CrossProduct] operator.

    Pairs every left row with every right row, concatenating their fields. Both
    sub-plans are evaluated through the [eval_relation] recursor handed in by
    {!Eval}. Out of scope: any join predicate — that is [NestedLoopJoin]. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  left:Plan.Physical.t ->
  right:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~left ~right continue]
    materialises [right] once (the outer loop over [left] re-iterates it) and
    hands [continue] a [Term.Relation_value] of every [left]×[right] pair with
    fields ordered left then right. *)
