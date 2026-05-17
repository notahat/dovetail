(** Tests for [Row_codec]: schema-driven decoding of stored rows. *)

open Dovetail

(* A schema with an int64 primary key column [id] and three non-PK columns,
   matching the [users] fixture's shape. *)
let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    primary_key = [ "id" ];
  }

let test_decode_row_round_trips_a_users_row () =
  let key_bytes = Encoding.encode_int64_key 7L in
  let value_bytes =
    Encoding.encode_tuple_value
      [
        Value.String "Alice"; Value.String "alice@example.com"; Value.Bool true;
      ]
  in
  let tuple = Row_codec.decode_row users_schema (key_bytes, value_bytes) in
  let expected : Schema.tuple =
    [|
      Value.Int64 7L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  Alcotest.(check bool) "tuple matches expected" true (tuple = expected)

let test_decode_row_raises_for_composite_primary_key () =
  let composite_schema : Schema.t =
    {
      fields =
        [
          { name = "left_id"; kind = Int64; qualifier = None };
          { name = "right_id"; kind = Int64; qualifier = None };
        ];
      primary_key = [ "left_id"; "right_id" ];
    }
  in
  Alcotest.check_raises "composite primary key"
    (Failure
       "Row_codec: only single-column primary keys are supported in slice 1")
    (fun () ->
      ignore (Row_codec.decode_row composite_schema ("ignored", "ignored")))

let test_decode_row_raises_for_non_int64_primary_key () =
  let string_pk_schema : Schema.t =
    {
      fields = [ { name = "id"; kind = String; qualifier = None } ];
      primary_key = [ "id" ];
    }
  in
  Alcotest.check_raises "string primary key"
    (Failure
       "Row_codec: only int64 primary-key columns are supported in slice 1")
    (fun () ->
      ignore (Row_codec.decode_row string_pk_schema ("ignored", "ignored")))

let test_encode_row_round_trips_through_decode_row () =
  let tuple : Schema.tuple =
    [|
      Value.Int64 42L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  let key_bytes, value_bytes = Row_codec.encode_row users_schema tuple in
  let decoded = Row_codec.decode_row users_schema (key_bytes, value_bytes) in
  Alcotest.(check bool) "round-trip matches original" true (decoded = tuple)

let test_encode_row_raises_for_composite_primary_key () =
  let composite_schema : Schema.t =
    {
      fields =
        [
          { name = "left_id"; kind = Int64; qualifier = None };
          { name = "right_id"; kind = Int64; qualifier = None };
        ];
      primary_key = [ "left_id"; "right_id" ];
    }
  in
  Alcotest.check_raises "composite primary key"
    (Failure
       "Row_codec: only single-column primary keys are supported in slice 1")
    (fun () ->
      ignore
        (Row_codec.encode_row composite_schema
           [| Value.Int64 1L; Value.Int64 2L |]))

let test_encode_row_raises_for_wrong_arity_tuple () =
  Alcotest.check_raises "tuple shorter than schema"
    (Invalid_argument
       "Row_codec.encode_row: tuple has 2 value(s) but schema declares 4 \
        field(s)") (fun () ->
      ignore
        (Row_codec.encode_row users_schema
           [| Value.Int64 7L; Value.String "Alice" |]))

let () =
  Alcotest.run "row_codec"
    [
      ( "decode_row",
        [
          Alcotest.test_case "reconstructs a tuple from key and value bytes"
            `Quick test_decode_row_round_trips_a_users_row;
          Alcotest.test_case "raises for a composite primary key" `Quick
            test_decode_row_raises_for_composite_primary_key;
          Alcotest.test_case "raises for a non-int64 primary-key column" `Quick
            test_decode_row_raises_for_non_int64_primary_key;
        ] );
      ( "encode_row",
        [
          Alcotest.test_case "round-trips a tuple through decode_row" `Quick
            test_encode_row_round_trips_through_decode_row;
          Alcotest.test_case "raises for a composite primary key" `Quick
            test_encode_row_raises_for_composite_primary_key;
          Alcotest.test_case "raises when tuple length doesn't match schema"
            `Quick test_encode_row_raises_for_wrong_arity_tuple;
        ] );
    ]
