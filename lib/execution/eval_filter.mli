(** The physical [Filter] operator.

    Wraps a sub-plan's row sequence in a predicate guard, passing the kind and
    multiplicity tag through unchanged. The sub-plan is evaluated through the
    [eval_relation] recursor handed in by {!Eval}, rather than calling back into
    {!Eval} directly, which would make the modules mutually dependent. Out of
    scope: resolving or type-checking the predicate — that is [Plan.Typecheck]'s
    job, done before this runs. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Expression = Dovetail_core.Expression
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  input:Plan.Physical.t ->
  predicate:Expression.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~input ~predicate continue]
    evaluates [input] via [eval_relation], filters its rows by [predicate], and
    hands [continue] a [Term.Relation_value] with the same kind as the input.
    The filter is lazy: the predicate runs as rows are pulled. *)
