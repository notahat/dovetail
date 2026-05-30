(** The physical [Insert] operator.

    Evaluates a source sub-plan through the [eval_relation] recursor handed in
    by {!Eval} and writes each row it produces into a target table, reporting a
    one-row [(insert_count : int64)] result. Out of scope: choosing the
    transaction kind — the caller routes write plans to a write transaction via
    [Logical.required_access] before [Eval] runs. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  target_table:string ->
  source:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~target_table ~source
     continue] evaluates [source] and writes its rows into [target_table],
    handing [continue] a one-row relation counting the writes. Multi-row inserts
    commit all-or-nothing: a raise (e.g. a primary-key collision) aborts the
    in-flight write transaction, discarding earlier writes. *)
