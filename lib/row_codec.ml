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

(* Locate the primary-key column's position in [schema.fields], so we can
   pull its value out of a tuple given in field order. *)
let primary_key_position (schema : Schema.t) primary_key_name =
  match
    Schema.find_field schema { qualifier = None; name = primary_key_name }
  with
  | Ok (position, _field) -> position
  (* Internal invariant: catalog construction guarantees every name in
     [schema.primary_key] is present in [schema.fields]. *)
  | Error _ -> assert false

(* Split [tuple] into the single PK value and the remaining values, in
   field order. Slice 1 only supports a single-column primary key. *)
let split_primary_key (schema : Schema.t) tuple =
  match schema.primary_key with
  | [ primary_key_name ] ->
      let pk_position = primary_key_position schema primary_key_name in
      let length = Array.length tuple in
      let primary_key_value = tuple.(pk_position) in
      let non_primary_key_values =
        let buffer = ref [] in
        for position = length - 1 downto 0 do
          if position <> pk_position then buffer := tuple.(position) :: !buffer
        done;
        !buffer
      in
      (primary_key_value, non_primary_key_values)
  | _ ->
      failwith
        "Row_codec: only single-column primary keys are supported in slice 1"

let encode_row (schema : Schema.t) tuple =
  let expected_length = List.length schema.fields in
  if Array.length tuple <> expected_length then
    invalid_arg
      (Printf.sprintf
         "Row_codec.encode_row: tuple has %d value(s) but schema declares %d \
          field(s)"
         (Array.length tuple) expected_length);
  let primary_key_value, non_primary_key_values =
    split_primary_key schema tuple
  in
  let key_bytes =
    match primary_key_value with
    | Value.Int64 key -> Encoding.encode_int64_key key
    | Value.String _ | Value.Bool _ ->
        failwith
          "Row_codec: only int64 primary-key columns are supported in slice 1"
  in
  let value_bytes = Encoding.encode_tuple_value non_primary_key_values in
  (key_bytes, value_bytes)
