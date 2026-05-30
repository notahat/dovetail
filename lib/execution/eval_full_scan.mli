(** The physical [FullScan] operator.

    Streams every row of a base table by opening a storage cursor and handing
    the consumer a relation backed by it. Out of scope: any filtering or
    projection — those are their own operators layered on top. *)

module Storage = Dovetail_storage
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  string ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction table_name continue] opens a cursor over
    [table_name] for the duration of [continue] and hands it a
    [Term.Relation_value] whose rows are pulled lazily from the live cursor. *)
