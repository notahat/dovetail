let table_subdb_name table = "table:" ^ table

(* Look up the schema and storage handle for a table referenced in a plan.
   Shared between the eager and streaming [FullScan] evaluators so they
   produce identical errors when the catalog or storage is missing. *)
let lookup_table_resources environment transaction table =
  let schema =
    match Catalog.get environment transaction ~table_name:table with
    | Some schema -> schema
    | None -> failwith (Printf.sprintf "Eval: unknown table %S" table)
  in
  let table_map =
    match
      Storage.open_map environment transaction ~name:(table_subdb_name table)
    with
    | Some map -> map
    | None ->
        failwith
          (Printf.sprintf
             "Eval: catalog has schema for %S but no storage subDB exists" table)
  in
  (schema, table_map)

let evaluate_full_scan environment transaction table =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  let tuples =
    Storage.iter_seq table_map transaction
    |> Seq.map (Row_codec.decode_row schema)
  in
  ({ schema; tuples } : [ `Bag ] Relation.t)

(* Streaming counterpart to [evaluate_full_scan]: opens the cursor for the
   duration of [continue] and hands it a relation whose tuples are pulled
   lazily from the live cursor. *)
let evaluate_full_scan_streaming environment transaction table continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  Storage.with_iter_seq table_map transaction (fun pairs ->
      let tuples = Seq.map (Row_codec.decode_row schema) pairs in
      continue ({ schema; tuples } : [ `Bag ] Relation.t))

let rec eval environment transaction plan =
  match (plan : Physical.t) with
  | FullScan { table } -> evaluate_full_scan environment transaction table
  | Filter { input; predicate } ->
      let { Relation.schema; tuples } = eval environment transaction input in
      let evaluator = Predicate.resolve schema predicate in
      { schema; tuples = Seq.filter evaluator tuples }
  | Project { input; columns } ->
      let { Relation.schema; tuples } = eval environment transaction input in
      let projected_schema, project_tuple = Projection.resolve schema columns in
      { schema = projected_schema; tuples = Seq.map project_tuple tuples }
  | CrossProduct { left; right } ->
      evaluate_cross_product environment transaction ~left ~right
  | NestedLoopJoin { left; right; predicate } ->
      evaluate_nested_loop_join environment transaction ~left ~right ~predicate

(* Nested-loop cross product. The right side is materialised into a list once
   so the outer loop can re-iterate it for every left tuple; streaming the
   right would otherwise require either re-evaluating the right sub-plan
   from scratch each iteration (expensive across operators) or threading
   cursor reset through the storage layer. With slice-4 fixtures the memory
   cost of materialisation is negligible. *)
and evaluate_cross_product environment transaction ~left ~right =
  let left_relation = eval environment transaction left in
  let right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.tuples in
  let combined_schema : Schema.t =
    {
      fields = left_relation.schema.fields @ right_relation.schema.fields;
      primary_key = [];
    }
  in
  let combined_tuples =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.map (fun right_tuple -> Array.append left_tuple right_tuple))
      left_relation.tuples
  in
  ({ schema = combined_schema; tuples = combined_tuples } : [ `Bag ] Relation.t)

(* Nested-loop join. Same shape as [evaluate_cross_product] -- right side
   materialised once, outer loop over left, inner loop over the materialised
   right -- with the predicate resolved against the combined schema and
   evaluated per (left, right) pair. Pairs that don't satisfy the predicate
   are dropped before the combined tuple is emitted. *)
and evaluate_nested_loop_join environment transaction ~left ~right ~predicate =
  let left_relation = eval environment transaction left in
  let right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.tuples in
  let combined_schema : Schema.t =
    {
      fields = left_relation.schema.fields @ right_relation.schema.fields;
      primary_key = [];
    }
  in
  let evaluate_predicate = Predicate.resolve combined_schema predicate in
  let combined_tuples =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.filter_map (fun right_tuple ->
            let combined = Array.append left_tuple right_tuple in
            if evaluate_predicate combined then Some combined else None))
      left_relation.tuples
  in
  ({ schema = combined_schema; tuples = combined_tuples } : [ `Bag ] Relation.t)

(* CPS-shaped executor under construction: each operator's streaming branch
   lands here one step at a time. Branches that have not yet been converted
   fall through to [eval] and pass the eagerly-built relation to [continue].
*)
let rec eval_cps environment transaction plan continue =
  match (plan : Physical.t) with
  | FullScan { table } ->
      evaluate_full_scan_streaming environment transaction table continue
  | Filter { input; predicate } ->
      eval_cps environment transaction input (fun input_relation ->
          let evaluate_predicate =
            Predicate.resolve input_relation.schema predicate
          in
          continue
            {
              schema = input_relation.schema;
              tuples = Seq.filter evaluate_predicate input_relation.tuples;
            })
  | Project { input; columns } ->
      eval_cps environment transaction input (fun input_relation ->
          let projected_schema, project_tuple =
            Projection.resolve input_relation.schema columns
          in
          continue
            {
              schema = projected_schema;
              tuples = Seq.map project_tuple input_relation.tuples;
            })
  | CrossProduct { left; right } ->
      (* Nested CPS: open the left scope first, then the right scope inside
         it, then call [continue] at the deepest point. The right side is
         still materialised via [List.of_seq] because the outer loop over
         left tuples re-iterates it -- a one-shot streaming seq can't be
         replayed, and streaming both sides would require a different join
         algorithm (hash, merge). *)
      eval_cps environment transaction left (fun left_relation ->
          eval_cps environment transaction right (fun right_relation ->
              let right_tuples = List.of_seq right_relation.tuples in
              let combined_schema : Schema.t =
                {
                  fields =
                    left_relation.schema.fields @ right_relation.schema.fields;
                  primary_key = [];
                }
              in
              let combined_tuples =
                Seq.flat_map
                  (fun left_tuple ->
                    List.to_seq right_tuples
                    |> Seq.map (fun right_tuple ->
                        Array.append left_tuple right_tuple))
                  left_relation.tuples
              in
              continue { schema = combined_schema; tuples = combined_tuples }))
  | _ -> continue (eval environment transaction plan)
