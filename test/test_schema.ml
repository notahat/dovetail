(** Tests for [Schema]. *)

open Dovetail

let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64 };
        { name = "name"; kind = String };
        { name = "email"; kind = String };
        { name = "active"; kind = Bool };
      ];
    primary_key = [ "id" ];
  }

(* A schema where the PK is in the middle of the field list, exercising
   that [assemble_tuple] interleaves by field order rather than appending. *)
let mid_pk_schema : Schema.t =
  {
    fields =
      [
        { name = "name"; kind = String };
        { name = "id"; kind = Int64 };
        { name = "active"; kind = Bool };
      ];
    primary_key = [ "id" ];
  }

let composite_pk_schema : Schema.t =
  {
    fields =
      [
        { name = "tenant"; kind = String };
        { name = "name"; kind = String };
        { name = "id"; kind = Int64 };
      ];
    primary_key = [ "tenant"; "id" ];
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
    ]
