(** Shared row-writing for the table-writing operators (insert, seeded create
    table).

    Turns a source relation's rows into stored rows under a target kind: rejects
    qualified sources, maps source columns onto target columns by name, and
    writes each row with a primary-key collision check. Out of scope: choosing
    or provisioning the target table, and building the operators' result
    relations. *)

module Storage = Dovetail_storage
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

val reject_qualified_source_for_target :
  error_prefix:string -> source_row_kind:Row.kind -> unit
(** [reject_qualified_source_for_target ~error_prefix ~source_row_kind] raises
    [Failure] if any field in [source_row_kind] carries a qualifier. Row-writing
    sinks store rows under bare names, so a qualified source -- typically the
    output of a join -- is ambiguous; the error names every offending field and
    points at the [unqualify] operator. [error_prefix] is the already-formatted
    operator-named prefix (e.g. [Insert: into "orders"]) the caller supplies. *)

val write_source_rows_into_table :
  error_prefix:string ->
  target_kind:Relation.kind ->
  target_map:Storage.Engine.map ->
  write_transaction:[ `Read | `Write ] Storage.Engine.transaction ->
  source_relation:_ Relation.t ->
  int
(** [write_source_rows_into_table ~error_prefix ~target_kind ~target_map
     ~write_transaction ~source_relation] streams [source_relation]'s rows into
    [target_map], reordering each into [target_kind]'s field order and failing
    on a primary-key collision. Returns the number of rows written. Runs the
    qualifier-rejection check first; [error_prefix] appears in every user-facing
    error this raises. *)
