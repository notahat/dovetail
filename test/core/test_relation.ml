(** Tests for [Relation]. *)

open Dovetail_core

(* The fixture's [users] schema, with qualifiers set just like {!Fixture}
   writes them, so the rendered headers show [users.<column>]. *)
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

(* A schema with no qualifier on its fields. Stands in for derived relations
   that lose qualifier information (e.g. {!Projection.resolve} keeps the
   input's qualifier today, but a future expression-projection step might
   not), so the printer keeps working when [qualifier = None]. *)
let unqualified_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    primary_key = [];
  }

let two_users : Schema.tuple list =
  [
    [|
      Value.Int64 1L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 10L;
      Value.String "Bob";
      Value.String "bob@example.com";
      Value.Bool false;
    |];
  ]

let render relation =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.print ~formatter relation;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_renders_aligned_table_with_qualified_headers () =
  let relation : [ `Bag ] Relation.t =
    { schema = users_schema; tuples = List.to_seq two_users }
  in
  let expected =
    String.concat "\n"
      [
        "│ users.id │ users.name │ users.email       │ users.active │";
        "├──────────┼────────────┼───────────────────┼──────────────┤";
        "│        1 │ Alice      │ alice@example.com │ true         │";
        "│       10 │ Bob        │ bob@example.com   │ false        │";
        "";
      ]
  in
  Alcotest.(check string) "rendered table" expected (render relation)

let test_renders_unqualified_headers_when_fields_have_no_qualifier () =
  let relation : [ `Bag ] Relation.t =
    {
      schema = unqualified_schema;
      tuples = List.to_seq [ [| Value.Int64 1L; Value.String "Alice" |] ];
    }
  in
  let expected =
    String.concat "\n"
      [ "│ id │ name  │"; "├────┼───────┤"; "│  1 │ Alice │"; "" ]
  in
  Alcotest.(check string) "rendered table" expected (render relation)

let test_renders_header_only_when_empty () =
  let relation : [ `Bag ] Relation.t =
    { schema = users_schema; tuples = Seq.empty }
  in
  let expected =
    String.concat "\n"
      [
        "│ users.id │ users.name │ users.email │ users.active │";
        "├──────────┼────────────┼─────────────┼──────────────┤";
        "";
      ]
  in
  Alcotest.(check string) "header-only table" expected (render relation)

(* Schema → Relation.kind → Schema round-trip helper. Asserts the
   converted-then-converted-back schema matches the original. *)
let assert_schema_round_trips (schema : Schema.t) =
  let kind = Relation.kind_of_schema schema in
  let recovered = Relation.schema_of_kind kind in
  Alcotest.(check bool) "schema round-trips" true (recovered = schema)

let test_schema_round_trip_with_single_column_primary_key () =
  assert_schema_round_trips users_schema

let test_schema_round_trip_with_no_primary_key () =
  assert_schema_round_trips unqualified_schema

let test_schema_round_trip_with_composite_primary_key () =
  let schema : Schema.t =
    {
      fields =
        [
          { name = "order_id"; kind = Int64; qualifier = None };
          { name = "product_id"; kind = Int64; qualifier = None };
          { name = "quantity"; kind = Int64; qualifier = None };
        ];
      primary_key = [ "order_id"; "product_id" ];
    }
  in
  assert_schema_round_trips schema

let test_kind_with_primary_key_refinement_round_trips () =
  let kind : Relation.kind =
    {
      row_kind = [ { Row.name = "id"; kind = Int64; qualifier = Some "users" } ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  let schema = Relation.schema_of_kind kind in
  let recovered = Relation.kind_of_schema schema in
  Alcotest.(check bool) "kind round-trips" true (recovered = kind)

let () =
  Alcotest.run "relation"
    [
      ( "print",
        [
          Alcotest.test_case "renders an aligned table with qualified headers"
            `Quick test_renders_aligned_table_with_qualified_headers;
          Alcotest.test_case
            "renders bare headers when fields have no qualifier" `Quick
            test_renders_unqualified_headers_when_fields_have_no_qualifier;
          Alcotest.test_case
            "renders just the header when the relation has no tuples" `Quick
            test_renders_header_only_when_empty;
        ] );
      ( "kind_of_schema / schema_of_kind",
        [
          Alcotest.test_case
            "Schema with a single-column primary key round-trips" `Quick
            test_schema_round_trip_with_single_column_primary_key;
          Alcotest.test_case "Schema with no primary key round-trips" `Quick
            test_schema_round_trip_with_no_primary_key;
          Alcotest.test_case "Schema with a composite primary key round-trips"
            `Quick test_schema_round_trip_with_composite_primary_key;
          Alcotest.test_case
            "Relation.kind with a Primary_key refinement round-trips" `Quick
            test_kind_with_primary_key_refinement_round_trips;
        ] );
    ]
