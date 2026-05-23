(** Tests for [Row_codec]: kind-driven decoding of stored rows. *)

open Dovetail_core
module Storage = Dovetail_storage

(* A kind with an int64 primary key column [id] and three non-PK columns,
   matching the [users] fixture's shape. *)
let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let test_decode_row_round_trips_a_users_row () =
  let key_bytes = Storage.Encoding.encode_int64_key 7L in
  let value_bytes =
    Storage.Encoding.encode_row_value
      [
        Value.String "Alice"; Value.String "alice@example.com"; Value.Bool true;
      ]
  in
  let row = Storage.Row_codec.decode_row users_kind (key_bytes, value_bytes) in
  let expected : Row.data =
    [|
      Value.Int64 7L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  Alcotest.(check bool) "row matches expected" true (row = expected)

let test_decode_row_raises_for_composite_primary_key () =
  let composite_kind : Relation.kind =
    {
      row_kind =
        [
          { name = "left_id"; kind = Int64; qualifier = None };
          { name = "right_id"; kind = Int64; qualifier = None };
        ];
      refinements = [ Primary_key [ "left_id"; "right_id" ] ];
    }
  in
  Alcotest.check_raises "composite primary key"
    (Failure "Row_codec: only single-column primary keys are supported")
    (fun () ->
      ignore
        (Storage.Row_codec.decode_row composite_kind ("ignored", "ignored")))

let test_decode_row_raises_for_non_int64_primary_key () =
  let string_pk_kind : Relation.kind =
    {
      row_kind = [ { name = "id"; kind = String; qualifier = None } ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  Alcotest.check_raises "string primary key"
    (Failure "Row_codec: only int64 primary-key columns are supported")
    (fun () ->
      ignore
        (Storage.Row_codec.decode_row string_pk_kind ("ignored", "ignored")))

let test_encode_row_round_trips_through_decode_row () =
  let row : Row.data =
    [|
      Value.Int64 42L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  let key_bytes, value_bytes = Storage.Row_codec.encode_row users_kind row in
  let decoded =
    Storage.Row_codec.decode_row users_kind (key_bytes, value_bytes)
  in
  Alcotest.(check bool) "round-trip matches original" true (decoded = row)

let test_encode_row_raises_for_composite_primary_key () =
  let composite_kind : Relation.kind =
    {
      row_kind =
        [
          { name = "left_id"; kind = Int64; qualifier = None };
          { name = "right_id"; kind = Int64; qualifier = None };
        ];
      refinements = [ Primary_key [ "left_id"; "right_id" ] ];
    }
  in
  Alcotest.check_raises "composite primary key"
    (Failure "Row_codec: only single-column primary keys are supported")
    (fun () ->
      ignore
        (Storage.Row_codec.encode_row composite_kind
           [| Value.Int64 1L; Value.Int64 2L |]))

let test_encode_row_raises_for_wrong_arity_row () =
  Alcotest.check_raises "row shorter than kind"
    (Invalid_argument
       "Relation.split_row: row has 2 value(s) but kind declares 4 field(s)")
    (fun () ->
      ignore
        (Storage.Row_codec.encode_row users_kind
           [| Value.Int64 7L; Value.String "Alice" |]))

let () =
  Alcotest.run "row_codec"
    [
      ( "decode_row",
        [
          Alcotest.test_case "reconstructs a row from key and value bytes"
            `Quick test_decode_row_round_trips_a_users_row;
          Alcotest.test_case "raises for a composite primary key" `Quick
            test_decode_row_raises_for_composite_primary_key;
          Alcotest.test_case "raises for a non-int64 primary-key column" `Quick
            test_decode_row_raises_for_non_int64_primary_key;
        ] );
      ( "encode_row",
        [
          Alcotest.test_case "round-trips a row through decode_row" `Quick
            test_encode_row_round_trips_through_decode_row;
          Alcotest.test_case "raises for a composite primary key" `Quick
            test_encode_row_raises_for_composite_primary_key;
          Alcotest.test_case "raises when row length doesn't match kind" `Quick
            test_encode_row_raises_for_wrong_arity_row;
        ] );
    ]
