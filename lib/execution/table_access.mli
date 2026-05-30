(** Shared storage-access helpers for the physical operators.

    The operators that read a base table all start from a table name and need
    two things: the table's catalog kind, and a way to pull its rows from
    storage. This module owns that translation so the individual operator
    modules don't each re-derive it.

    Out of scope: any operator logic, and any recursion into sub-plans — that
    lives in the operator modules and {!Eval}. *)

module Relation = Dovetail_core.Relation
module Storage = Dovetail_storage

val lookup_table_resources :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  string ->
  Relation.kind * Storage.Engine.map
(** [lookup_table_resources environment transaction table_name] returns the
    catalog kind and storage handle for [table_name]. [Plan.Typecheck]
    guarantees the catalog has a kind for every referenced table, so a missing
    kind is an internal invariant violation (raises via [assert false]). Raises
    [Failure] if the catalog has a kind but no storage subDB exists — a true
    catalog/storage divergence. *)

val build_table_relation :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  table_name:string ->
  (_ Relation.t -> 'a) ->
  'a
(** [build_table_relation environment transaction ~table_name continue] opens a
    cursor over [table_name]'s storage for the duration of [continue] and hands
    it a relation whose [value] seq pulls rows directly from the live cursor.
    The relation is valid only while [continue] runs. The multiplicity tag is
    left polymorphic; callers commit to [`Bag] (a full scan) or [`Set] (the
    catalog source) at the call site. *)
