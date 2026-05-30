module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

(* Create [table_name] from [source]'s row kind and seed it with [source]'s
   rows in a single write transaction. Derivation order matches the
   layered validation: read the source's static kind, reject a qualified
   source (pointing at [unqualify]), stamp the new table's name onto every
   field, run the structural checks (no-PK is the user-visible one),
   reject a name collision -- all before any storage mutation. Then
   provision storage and catalog, evaluate [source], and stream its rows
   through {!Row_writer.write_source_rows_into_table}. *)
let evaluate ~eval_relation environment transaction ~table_name ~source continue
    =
  let write_transaction : [ `Read | `Write ] Storage.Engine.transaction =
    Obj.magic transaction
  in
  let catalog table_name =
    Storage.Catalog.get environment write_transaction ~table_name
  in
  let source_kind = Plan.Physical.kind_of ~catalog source in
  let error_prefix = Printf.sprintf "Create table: %S" table_name in
  Row_writer.reject_qualified_source_for_target ~error_prefix
    ~source_row_kind:source_kind.row_kind;
  let target_kind =
    Table_provisioning.stamp_qualifier_on_kind ~qualifier:table_name source_kind
  in
  Table_provisioning.validate_target_kind ~table_name target_kind;
  Table_provisioning.reject_existing_table environment write_transaction
    ~table_name;
  let target_map =
    Table_provisioning.provision_table environment write_transaction ~table_name
      ~kind:target_kind
  in
  eval_relation environment transaction source (fun source_relation ->
      let _written =
        Row_writer.write_source_rows_into_table ~error_prefix ~target_kind
          ~target_map ~write_transaction ~source_relation
      in
      continue
        (Term.Relation_value
           (Mutation_result.relation ~verb:"created" table_name)))
