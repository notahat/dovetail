(** The physical [Tables] operator.

    Projects a catalog source down to a one-column relation of table names. It
    evaluates its input through the [eval] recursor handed in by {!Eval} — the
    full-term form, since its input is a catalog rather than a relation. Out of
    scope: any column other than the table name. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval:('perm, 'a) Eval_recurse.eval ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  input:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval environment transaction ~input continue] evaluates [input]
    to a catalog and streams one [`Set]-tagged row per table, with kind
    [(name : string)]. *)
