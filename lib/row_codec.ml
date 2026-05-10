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
            "Row_codec: only int64 primary-key columns are supported in slice 1"
      )
  | _ ->
      failwith
        "Row_codec: only single-column primary keys are supported in slice 1"

let decode_row schema (key_bytes, value_bytes) =
  let primary_key_values = decode_primary_key schema key_bytes in
  let non_primary_key_values = Encoding.decode_tuple_value value_bytes in
  Schema.assemble_tuple schema ~primary_key_values ~non_primary_key_values
