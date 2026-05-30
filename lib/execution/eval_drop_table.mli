(** The physical [Drop_table] operator.

    Removes a table from the catalog and storage. Out of scope: any cascade to
    dependent objects — there are none in the model today. *)

module Storage = Dovetail_storage
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  table_name:string ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction ~table_name continue] rejects an unknown
    table first, then drops the storage subDB before the catalog entry so a
    partial commit cannot leave orphan rows under a still-present catalog
    binding. Hands [continue] the one-row [(dropped : string)] result.
    [transaction] is widened to a write transaction; the caller has routed write
    plans accordingly. *)
