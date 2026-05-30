module Storage = Dovetail_storage
module Term = Dovetail_core.Term

(* Drop [table_name] from the catalog and storage. Mirrors
   {!Ddl_executor.drop_table}'s ordering: rejects an unknown table first,
   then drops the storage subDB before the catalog entry so a partial
   commit cannot leave orphan rows under a still-present catalog binding.

   [transaction] is widened to a write transaction via [Obj.magic]: the
   upstream invariant is that {!Plan.Logical.required_access} reports
   [`Write] for any plan containing [Drop_table], so the REPL has already
   opened a write transaction by the time this operator runs. Same
   template as {!Eval_insert}. *)
let evaluate environment transaction ~table_name continue =
  let write_transaction : [ `Read | `Write ] Storage.Engine.transaction =
    Obj.magic transaction
  in
  (match Storage.Catalog.get environment write_transaction ~table_name with
  | Some _ -> ()
  | None -> failwith (Printf.sprintf "Drop table: %S: no such table" table_name));
  Storage.Engine.drop_map environment write_transaction
    ~name:(Storage.Catalog.table_subdb_name table_name);
  Storage.Catalog.delete environment write_transaction ~table_name;
  continue
    (Term.Relation_value (Mutation_result.relation ~verb:"dropped" table_name))
