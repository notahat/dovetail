(** Tests for [Schema]. *)

open Dovetail
open Test_helpers

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

(* A schema where the PK is in the middle of the field list, exercising
   that [assemble_tuple] interleaves by field order rather than appending. *)
let mid_pk_schema : Schema.t =
  {
    fields =
      [
        { name = "name"; kind = String; qualifier = None };
        { name = "id"; kind = Int64; qualifier = None };
        { name = "active"; kind = Bool; qualifier = None };
      ];
    primary_key = [ "id" ];
  }

let composite_pk_schema : Schema.t =
  {
    fields =
      [
        { name = "tenant"; kind = String; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
        { name = "id"; kind = Int64; qualifier = None };
      ];
    primary_key = [ "tenant"; "id" ];
  }

(* A schema modelling the cross-product of users and orders: same-named [id]
   columns appear under different qualifiers, exercising the
   ambiguity-resolution path for unqualified references. *)
let cross_product_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
      ];
    primary_key = [];
  }

let tuple_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<tuple>")) ( = )

let test_assembles_in_field_order_with_leading_pk () =
  let assembled =
    Schema.assemble_tuple users_schema ~primary_key_values:[ Value.Int64 42L ]
      ~non_primary_key_values:
        [
          Value.String "Alice";
          Value.String "alice@example.com";
          Value.Bool true;
        ]
  in
  let expected : Schema.tuple =
    [|
      Value.Int64 42L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  Alcotest.(check tuple_testable) "leading PK" expected assembled

let test_assembles_with_pk_in_the_middle () =
  let assembled =
    Schema.assemble_tuple mid_pk_schema ~primary_key_values:[ Value.Int64 7L ]
      ~non_primary_key_values:[ Value.String "Bob"; Value.Bool false ]
  in
  let expected : Schema.tuple =
    [| Value.String "Bob"; Value.Int64 7L; Value.Bool false |]
  in
  Alcotest.(check tuple_testable) "PK in middle" expected assembled

let test_assembles_composite_primary_key () =
  let assembled =
    Schema.assemble_tuple composite_pk_schema
      ~primary_key_values:[ Value.String "acme"; Value.Int64 3L ]
      ~non_primary_key_values:[ Value.String "Carol" ]
  in
  let expected : Schema.tuple =
    [| Value.String "acme"; Value.String "Carol"; Value.Int64 3L |]
  in
  Alcotest.(check tuple_testable) "composite PK" expected assembled

let test_unqualified_lookup_returns_position_and_field () =
  match Schema.find_field users_schema (column_reference "id") with
  | Ok (position, field) ->
      Alcotest.(check int) "id at position 0" 0 position;
      Alcotest.(check string) "field name" "id" field.name
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_unqualified_lookup_returns_position_for_later_field () =
  match Schema.find_field users_schema (column_reference "active") with
  | Ok (position, field) ->
      Alcotest.(check int) "active at position 3" 3 position;
      Alcotest.(check string) "field name" "active" field.name
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_qualified_lookup_returns_position_and_field () =
  match
    Schema.find_field users_schema
      (qualified_column_reference ~qualifier:"users" ~name:"id")
  with
  | Ok (position, _field) ->
      Alcotest.(check int) "users.id at position 0" 0 position
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_unqualified_lookup_unknown_returns_error () =
  match Schema.find_field users_schema (column_reference "missing") with
  | Ok _ -> Alcotest.fail "expected an error for missing column"
  | Error message ->
      Alcotest.(check string)
        "error names the column" "unknown column \"missing\"" message

let test_qualified_lookup_unknown_returns_error () =
  match
    Schema.find_field users_schema
      (qualified_column_reference ~qualifier:"orders" ~name:"id")
  with
  | Ok _ -> Alcotest.fail "expected an error for orders.id against users"
  | Error message ->
      Alcotest.(check string)
        "error names the qualified column" "unknown column \"orders.id\""
        message

let test_unqualified_lookup_ambiguous_returns_error_naming_qualifiers () =
  match Schema.find_field cross_product_schema (column_reference "id") with
  | Ok _ -> Alcotest.fail "expected an ambiguity error"
  | Error message ->
      Alcotest.(check string)
        "error names both qualifiers"
        "ambiguous column reference \"id\": matches \"users.id\" and \
         \"orders.id\""
        message

let values_list_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<values>")) ( = )

let test_splits_tuple_with_leading_pk () =
  let tuple : Schema.tuple =
    [|
      Value.Int64 42L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |]
  in
  let primary_key_values, non_primary_key_values =
    Schema.split_tuple users_schema tuple
  in
  Alcotest.(check values_list_testable)
    "primary-key values" [ Value.Int64 42L ] primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values"
    [ Value.String "Alice"; Value.String "alice@example.com"; Value.Bool true ]
    non_primary_key_values

let test_splits_tuple_with_pk_in_the_middle () =
  let tuple : Schema.tuple =
    [| Value.String "Bob"; Value.Int64 7L; Value.Bool false |]
  in
  let primary_key_values, non_primary_key_values =
    Schema.split_tuple mid_pk_schema tuple
  in
  Alcotest.(check values_list_testable)
    "primary-key values" [ Value.Int64 7L ] primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values in field order"
    [ Value.String "Bob"; Value.Bool false ]
    non_primary_key_values

let test_splits_tuple_with_composite_primary_key () =
  let tuple : Schema.tuple =
    [| Value.String "acme"; Value.String "Carol"; Value.Int64 3L |]
  in
  let primary_key_values, non_primary_key_values =
    Schema.split_tuple composite_pk_schema tuple
  in
  Alcotest.(check values_list_testable)
    "primary-key values in primary-key order"
    [ Value.String "acme"; Value.Int64 3L ]
    primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values" [ Value.String "Carol" ] non_primary_key_values

let test_split_is_the_inverse_of_assemble () =
  let tuple : Schema.tuple =
    [| Value.String "acme"; Value.String "Carol"; Value.Int64 3L |]
  in
  let primary_key_values, non_primary_key_values =
    Schema.split_tuple composite_pk_schema tuple
  in
  let reassembled =
    Schema.assemble_tuple composite_pk_schema ~primary_key_values
      ~non_primary_key_values
  in
  Alcotest.(check tuple_testable)
    "split then assemble round-trips the tuple" tuple reassembled

let test_split_rejects_wrong_length_tuple () =
  let tuple : Schema.tuple = [| Value.Int64 1L; Value.String "Alice" |] in
  Alcotest.check_raises "raises Invalid_argument"
    (Invalid_argument
       "Schema.split_tuple: tuple has 2 value(s) but schema declares 4 field(s)")
    (fun () -> ignore (Schema.split_tuple users_schema tuple))

let test_qualified_lookup_disambiguates_in_cross_product_schema () =
  match
    Schema.find_field cross_product_schema
      (qualified_column_reference ~qualifier:"orders" ~name:"id")
  with
  | Ok (position, _field) ->
      Alcotest.(check int) "orders.id at position 2" 2 position
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let () =
  Alcotest.run "schema"
    [
      ( "assemble_tuple",
        [
          Alcotest.test_case "interleaves values in field order with leading PK"
            `Quick test_assembles_in_field_order_with_leading_pk;
          Alcotest.test_case "interleaves values when PK sits in the middle"
            `Quick test_assembles_with_pk_in_the_middle;
          Alcotest.test_case "interleaves values for a composite primary key"
            `Quick test_assembles_composite_primary_key;
        ] );
      ( "split_tuple",
        [
          Alcotest.test_case "splits a tuple whose PK is the leading field"
            `Quick test_splits_tuple_with_leading_pk;
          Alcotest.test_case "splits a tuple whose PK sits in the middle" `Quick
            test_splits_tuple_with_pk_in_the_middle;
          Alcotest.test_case
            "splits a tuple with a composite primary key in PK order" `Quick
            test_splits_tuple_with_composite_primary_key;
          Alcotest.test_case "round-trips through assemble_tuple" `Quick
            test_split_is_the_inverse_of_assemble;
          Alcotest.test_case "rejects a tuple of the wrong length" `Quick
            test_split_rejects_wrong_length_tuple;
        ] );
      ( "find_field",
        [
          Alcotest.test_case
            "unqualified reference returns position and field for the first \
             field"
            `Quick test_unqualified_lookup_returns_position_and_field;
          Alcotest.test_case
            "unqualified reference returns position and field for a later field"
            `Quick test_unqualified_lookup_returns_position_for_later_field;
          Alcotest.test_case "qualified reference returns position and field"
            `Quick test_qualified_lookup_returns_position_and_field;
          Alcotest.test_case "unknown unqualified column returns error" `Quick
            test_unqualified_lookup_unknown_returns_error;
          Alcotest.test_case
            "unknown qualified column returns error using dotted name" `Quick
            test_qualified_lookup_unknown_returns_error;
          Alcotest.test_case
            "ambiguous unqualified column names the conflicting qualifiers"
            `Quick
            test_unqualified_lookup_ambiguous_returns_error_naming_qualifiers;
          Alcotest.test_case
            "qualified reference disambiguates within a cross-product schema"
            `Quick test_qualified_lookup_disambiguates_in_cross_product_schema;
        ] );
    ]
