module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* The static row shape an insert reports: a one-column [insert_count : int64]
   row. The kind has no refinements -- the relation describes an evaluation
   result, not a stored table. *)
let insert_result_kind : Relation.kind =
  {
    row_kind =
      [ { name = "insert_count"; kind = Scalar.Int64; qualifier = None } ];
    refinements = [];
  }

(* Wrap a row count as the one-row [insert_count : int64] relation. *)
let insert_result_relation count : [ `Set | `Bag ] Relation.t =
  {
    kind = insert_result_kind;
    value = Seq.return [| Scalar.Int64 (Int64.of_int count) |];
  }

(* Evaluate the [source] sub-plan inside its own resource scope and write each
   row it produces into [target_table]. Hands [continue] a one-row relation
   reporting how many rows were written.

   [transaction] is widened to a write transaction here. The invariant that
   makes this sound: [Logical.required_access] reports [`Write] for any plan
   containing [Insert], and the REPL routes such plans through
   [Storage.Engine.with_write_transaction]. So whenever this operator runs,
   the LMDB handle really does have write permissions -- the phantom type
   is just lower-precision than the runtime. Same upstream-invariant
   pattern as the [assert false] arms elsewhere in the codebase. *)
let evaluate ~eval_relation environment transaction ~target_table ~source
    continue =
  let write_transaction : [ `Read | `Write ] Storage.Engine.transaction =
    Obj.magic transaction
  in
  let target_kind, target_map =
    Table_access.lookup_table_resources environment write_transaction
      target_table
  in
  let error_prefix = Printf.sprintf "Insert: into %S" target_table in
  eval_relation environment transaction source (fun source_relation ->
      let affected_rows =
        Row_writer.write_source_rows_into_table ~error_prefix ~target_kind
          ~target_map ~write_transaction ~source_relation
      in
      continue (Term.Relation_value (insert_result_relation affected_rows)))
