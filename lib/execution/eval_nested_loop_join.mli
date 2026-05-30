(** The physical [NestedLoopJoin] operator.

    Pairs left and right rows like a cross product, but keeps only the pairs
    satisfying a predicate, which is fused into the inner loop. Both sub-plans
    are evaluated through the [eval_relation] recursor handed in by {!Eval}. Out
    of scope: index-assisted joins — that is [IndexedNestedLoopJoin]. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Expression = Dovetail_core.Expression
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  left:Plan.Physical.t ->
  right:Plan.Physical.t ->
  predicate:Expression.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~left ~right ~predicate
     continue] materialises [right] once, then for each [left]×[right] pair
    emits the combined row when [predicate] holds. Fields are ordered left then
    right; the predicate is resolved against the combined kind. *)
