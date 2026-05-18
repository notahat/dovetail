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
    ]
