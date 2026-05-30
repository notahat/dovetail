(** The physical [Project] operator.

    Maps each row of a sub-plan to a chosen set of columns, evaluating the
    sub-plan through the [eval_relation] recursor handed in by {!Eval}. Out of
    scope: resolving the projection or detecting duplicate columns — those run
    in [Plan.Typecheck] before this. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  input:Plan.Physical.t ->
  columns:Plan.Projection.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~input ~columns continue]
    evaluates [input], maps each row to [columns], and hands [continue] a
    [Term.Relation_value] with the projected kind. The projection is lazy. *)
