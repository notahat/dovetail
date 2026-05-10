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

let eval environment transaction plan =
  match (plan : Physical.t) with
  | FullScan { table } -> evaluate_full_scan environment transaction table
