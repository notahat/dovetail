let table_subdb_name table = "table:" ^ table

(* Look up the schema and storage handle for a table referenced in a plan.
   Raises [Failure] if the catalog has no schema for [table], or if the
   catalog has a schema but no storage subDB exists. *)
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

(* Open the cursor for the duration of [continue] and hand it a relation
   whose tuples are pulled lazily from the live cursor. *)
let evaluate_full_scan environment transaction table continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  Storage.with_iter_seq table_map transaction (fun pairs ->
      let tuples = Seq.map (Row_codec.decode_row schema) pairs in
      continue ({ schema; tuples } : [ `Bag ] Relation.t))

(* CPS-shaped executor. Every operator is in continuation-passing form so
   the consumer's [continue] runs inside whatever cursor and resource
   scopes the plan opens, letting tuples stream directly from live
   cursors rather than being eagerly materialised. *)
let rec eval environment transaction plan continue =
  match (plan : Physical.t) with
  | FullScan { table } ->
      evaluate_full_scan environment transaction table continue
  | Filter { input; predicate } ->
      evaluate_filter environment transaction ~input ~predicate continue
  | Project { input; columns } ->
      evaluate_project environment transaction ~input ~columns continue
  | CrossProduct { left; right } ->
      evaluate_cross_product environment transaction ~left ~right continue
  | NestedLoopJoin { left; right; predicate } ->
      evaluate_nested_loop_join environment transaction ~left ~right ~predicate
        continue

(* Stream the input through [eval], then wrap its tuple seq in a
   [Seq.filter] guarded by the resolved predicate. The schema is unchanged.
   Resolution happens inside the input's scope so type errors still surface
   before any tuples are pulled. *)
and evaluate_filter environment transaction ~input ~predicate continue =
  eval environment transaction input (fun input_relation ->
      let evaluate_predicate =
        Predicate.resolve input_relation.schema predicate
      in
      continue
        {
          schema = input_relation.schema;
          tuples = Seq.filter evaluate_predicate input_relation.tuples;
        })

(* Stream the input through [eval], then wrap its tuple seq in a [Seq.map]
   that projects each row to the requested columns. The projected schema
   is computed eagerly inside the input's scope so column-resolution
   errors surface before any tuples are pulled. *)
and evaluate_project environment transaction ~input ~columns continue =
  eval environment transaction input (fun input_relation ->
      let projected_schema, project_tuple =
        Projection.resolve input_relation.schema columns
      in
      continue
        {
          schema = projected_schema;
          tuples = Seq.map project_tuple input_relation.tuples;
        })

(* Nested CPS: open the left scope first, then the right scope inside it,
   then call [continue] at the deepest point so the consumer iterates with
   both cursors live. The right side is materialised via [List.of_seq]
   because the outer loop over left tuples re-iterates it -- a one-shot
   streaming seq can't be replayed, and streaming both sides would require
   a different join algorithm (hash, merge). *)
and evaluate_cross_product environment transaction ~left ~right continue =
  eval environment transaction left (fun left_relation ->
      eval environment transaction right (fun right_relation ->
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

(* Same shape as [evaluate_cross_product] -- nested CPS, right side
   materialised -- with the predicate resolved against the combined schema
   and evaluated per (left, right) pair before the combined tuple is
   emitted. *)
and evaluate_nested_loop_join environment transaction ~left ~right ~predicate
    continue =
  eval environment transaction left (fun left_relation ->
      eval environment transaction right (fun right_relation ->
          let right_tuples = List.of_seq right_relation.tuples in
          let combined_schema : Schema.t =
            {
              fields =
                left_relation.schema.fields @ right_relation.schema.fields;
              primary_key = [];
            }
          in
          let evaluate_predicate =
            Predicate.resolve combined_schema predicate
          in
          let combined_tuples =
            Seq.flat_map
              (fun left_tuple ->
                List.to_seq right_tuples
                |> Seq.filter_map (fun right_tuple ->
                    let combined = Array.append left_tuple right_tuple in
                    if evaluate_predicate combined then Some combined else None))
              left_relation.tuples
          in
          continue { schema = combined_schema; tuples = combined_tuples }))
