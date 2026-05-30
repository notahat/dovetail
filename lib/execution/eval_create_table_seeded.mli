(** The physical [Create_table_seeded] operator.

    Creates a new table from a source sub-plan's row kind and seeds it with that
    sub-plan's rows, all in one write transaction. The source is evaluated
    through the [eval_relation] recursor handed in by {!Eval}. Out of scope:
    creating an empty table — that is [Create_table_empty]. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  table_name:string ->
  source:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~table_name ~source
     continue] derives the new table's kind from [source], validates and
    provisions it, then streams [source]'s rows in. All validation
    (qualified-source rejection, structural checks, name-collision) runs before
    any storage mutation. Hands [continue] the one-row [(created : string)]
    result. *)
