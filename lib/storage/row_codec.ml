module Value = Dovetail_core.Value
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* Extract the primary-key column names from a [Relation.kind]'s refinements,
   or [[]] when no [Primary_key] refinement is present. *)
let primary_key_of_kind (kind : Relation.kind) =
  List.find_map
    (function Relation.Primary_key keys -> Some keys)
    kind.refinements
  |> Option.value ~default:[]

(* Encode [primary_key_values] as the storage key bytes. Currently only
   handles a single-column [Int64] primary key; any other shape raises
   [Failure]. The [Relation.split_tuple] / [Relation.assemble_tuple] pair
   already supports composite keys, so this restriction is purely about
   byte encoding. *)
let encode_primary_key = function
  | [ Value.Int64 key ] -> Encoding.encode_int64_key key
  | [ (Value.String _ | Value.Bool _) ] ->
      failwith "Row_codec: only int64 primary-key columns are supported"
  | _ -> failwith "Row_codec: only single-column primary keys are supported"

(* Inverse of [encode_primary_key]: decode the storage key bytes into the
   primary-key values list, in primary-key order. Same shape restrictions
   apply. *)
let decode_primary_key (kind : Relation.kind) key_bytes =
  match primary_key_of_kind kind with
  | [ primary_key_name ] -> (
      let primary_key_field =
        List.find
          (fun (field : Row.field) -> field.name = primary_key_name)
          kind.row_kind
      in
      match primary_key_field.kind with
      | Int64 -> [ Value.Int64 (Encoding.decode_int64_key key_bytes) ]
      | String | Bool ->
          failwith "Row_codec: only int64 primary-key columns are supported")
  | _ -> failwith "Row_codec: only single-column primary keys are supported"

let decode_row kind (key_bytes, value_bytes) =
  let primary_key_values = decode_primary_key kind key_bytes in
  let non_primary_key_values = Encoding.decode_tuple_value value_bytes in
  Relation.assemble_tuple kind ~primary_key_values ~non_primary_key_values

let encode_row kind row =
  let primary_key_values, non_primary_key_values =
    Relation.split_tuple kind row
  in
  let key_bytes = encode_primary_key primary_key_values in
  let value_bytes = Encoding.encode_tuple_value non_primary_key_values in
  (key_bytes, value_bytes)
