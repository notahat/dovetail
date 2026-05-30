(** The physical [IndexLookup] operator.

    Probes a table's storage by a single primary-key value, yielding the one
    matching row or none. Out of scope: range scans and multi-key lookups. *)

module Storage = Dovetail_storage
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  table:string ->
  key:int64 ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction ~table ~key continue] encodes [key],
    probes [table]'s storage with it, and hands [continue] a
    [Term.Relation_value] whose [value] seq has one element (the decoded row) or
    zero (no row at that key). The seq is a plain OCaml seq, not a live cursor,
    so it stays valid after [continue] returns. *)
