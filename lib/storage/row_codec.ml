module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* TODO(composite-pk): lift the single-column restriction once the binary
   key encoding handles multi-column keys. The [Relation.split_row] /
   [Relation.assemble_row] pair already supports composite keys; the
   blocker is here. *)

(* Validate that [kind]'s primary key is the single [Int64] column the
   storage format currently supports, and return that column's field.
   Both [encode_row] and [decode_row] funnel through this so the
   canonical error messages live in exactly one place. *)
let require_single_int64_primary_key_field (kind : Relation.kind) : Row.field =
  match Relation.primary_key_names kind with
  | [ primary_key_name ] -> (
      let primary_key_field =
        List.find
          (fun (field : Row.field) -> field.name = primary_key_name)
          kind.row_kind
      in
      match primary_key_field.kind with
      | Int64 -> primary_key_field
      | String | Bool ->
          failwith "Row_codec: only int64 primary-key columns are supported")
  | _ -> failwith "Row_codec: only single-column primary keys are supported"

let decode_row kind (key_bytes, value_bytes) =
  let _ : Row.field = require_single_int64_primary_key_field kind in
  let primary_key_values =
    [ Scalar.Int64 (Encoding.decode_int64_key key_bytes) ]
  in
  let non_primary_key_values = Encoding.decode_row_value value_bytes in
  Relation.assemble_row kind ~primary_key_values ~non_primary_key_values

let encode_row kind row =
  let _ : Row.field = require_single_int64_primary_key_field kind in
  let primary_key_values, non_primary_key_values =
    Relation.split_row kind row
  in
  let key_bytes =
    match primary_key_values with
    | [ Scalar.Int64 key ] -> Encoding.encode_int64_key key
    (* [require_single_int64_primary_key_field] above plus [split_row]'s
       kind-respecting projection guarantee this shape. *)
    | _ -> assert false
  in
  let value_bytes = Encoding.encode_row_value non_primary_key_values in
  (key_bytes, value_bytes)
