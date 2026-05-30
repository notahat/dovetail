(** The physical [Catalog_source] operator.

    Evaluates the bare [catalog] source: one entry per base table, each carrying
    that table's rows. Out of scope: the [tables] projection over the catalog,
    which is its own operator. *)

module Storage = Dovetail_storage
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction continue] enumerates the catalog's table
    names in cursor order and folds across them so every per-table cursor is
    open at the moment [continue] is called, handing it a [Term.Catalog_value].
    Each per-table relation is tagged [`Set] -- every base table is a set. *)
