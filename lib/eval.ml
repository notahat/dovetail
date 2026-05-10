let table_subdb_name table = "table:" ^ table

(* Decode the primary-key portion of a stored row from its key bytes, in the
   order the columns appear in [schema.primary_key]. Slice 1 only handles a
   single-column int64 primary key; any other shape raises [Failure]. *)
let decode_primary_key (schema : Schema.t) key_bytes =
  match schema.primary_key with
  | [ primary_key_name ] -> (
      let primary_key_field =
        List.find
          (fun (field : Schema.field) -> field.name = primary_key_name)
          schema.fields
      in
      match primary_key_field.kind with
      | Int64 -> [ Value.Int64 (Encoding.decode_int64_key key_bytes) ]
      | String | Bool ->
          failwith
            "Eval: only int64 primary-key columns are supported in slice 1")
  | _ ->
      failwith "Eval: only single-column primary keys are supported in slice 1"

let decode_row schema (key_bytes, value_bytes) =
  let primary_key_values = decode_primary_key schema key_bytes in
  let non_primary_key_values = Encoding.decode_tuple_value value_bytes in
  Schema.assemble_tuple schema ~primary_key_values ~non_primary_key_values

let evaluate_full_scan environment transaction table =
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
  let tuples =
    Storage.iter_seq table_map transaction |> Seq.map (decode_row schema)
  in
  ({ schema; tuples } : [ `Bag ] Relation.t)

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
