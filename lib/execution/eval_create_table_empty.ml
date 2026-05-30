module Storage = Dovetail_storage
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* Create [table_name] from a pre-resolved [kind]. Runs the catalog
   "table already exists" check before any storage mutation: a name
   collision leaves the catalog and storage untouched. The static-shape
   checks (non-empty fields, no duplicate field names, primary-key
   well-formedness) live in [Plan.Typecheck] and have already run by
   the time Eval sees [kind]. On success, provisions the storage subDB
   before the catalog entry; if anything raises in between, the
   transaction aborts and rolls both halves back.

   [transaction] is widened to a write transaction via [Obj.magic]; same
   upstream invariant as {!Eval_drop_table}. *)
let evaluate environment transaction ~table_name ~kind continue =
  let write_transaction : [ `Read | `Write ] Storage.Engine.transaction =
    Obj.magic transaction
  in
  let target_kind =
    Table_provisioning.stamp_qualifier_on_kind ~qualifier:table_name kind
  in
  Table_provisioning.reject_existing_table environment write_transaction
    ~table_name;
  let _target_map =
    Table_provisioning.provision_table environment write_transaction ~table_name
      ~kind:target_kind
  in
  continue
    (Term.Relation_value (Mutation_result.relation ~verb:"created" table_name))
