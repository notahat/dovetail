(** Validating and provisioning a new table for the create-table operators.

    Checks a proposed table kind, rejects a name collision, and creates the
    storage subDB and catalog entry. Out of scope: writing the seed rows (that
    is {!Row_writer}) and building the result relation (that is
    {!Mutation_result}). *)

module Storage = Dovetail_storage
module Relation = Dovetail_core.Relation

val stamp_qualifier_on_kind : qualifier:string -> Relation.kind -> Relation.kind
(** [stamp_qualifier_on_kind ~qualifier kind] stamps [Some qualifier] onto every
    field of [kind]'s row kind, leaving refinements untouched. Turns a source
    row kind (unqualified after the qualifier-rejection check) into the target
    catalog kind, qualified by the new table's name to match the rest of the
    catalog. *)

val validate_target_kind : table_name:string -> Relation.kind -> unit
(** [validate_target_kind ~table_name kind] runs the structural checks on a
    target [kind]: non-empty fields; no duplicate field names; non-empty primary
    key; PK columns drawn from the field list; no duplicate PK columns. Raises
    [Failure] with a [Create table: %S: ...] prefix on the first failing rule.
    Used by the seeded create-table evaluator, whose derived kind isn't visible
    to [Plan.Typecheck]; the empty form gets the same checks at typecheck time.
*)

val reject_existing_table :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  table_name:string ->
  unit
(** [reject_existing_table environment transaction ~table_name] raises [Failure]
    if the catalog already binds [table_name]. *)

val provision_table :
  Storage.Engine.environment ->
  [ `Read | `Write ] Storage.Engine.transaction ->
  table_name:string ->
  kind:Relation.kind ->
  Storage.Engine.map
(** [provision_table environment transaction ~table_name ~kind] creates the
    storage subDB before writing the catalog entry, so anything raising in
    between rolls both halves back via the enclosing write transaction. Returns
    the freshly-opened map handle so a seeded create can write rows into it
    without re-opening. *)
