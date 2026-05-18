(** Tests for [Projection]. *)

open Dovetail
open Dovetail_core
open Test_helpers

(* The fixture's [users] schema, repeated here so the projection tests are
   self-contained and don't need to spin up an LMDB environment. The
   qualifier is set to [Some "users"], matching what {!Fixture} writes. *)
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

let users_rows = expected_users_rows

(* Apply [projection] to every fixture row and return the projected rows. *)
let project_users projection =
  let _projected_schema, project_tuple =
    Projection.resolve users_schema projection
  in
  List.map project_tuple users_rows

let test_single_column_projection () =
  let rows = project_users [ column_reference "name" ] in
  let expected =
    [
      [| Value.String "Alice" |];
      [| Value.String "Bob" |];
      [| Value.String "Carol" |];
      [| Value.String "Dave" |];
      [| Value.String "Eve" |];
    ]
  in
  Alcotest.(check tuple_list_testable) "five single-column rows" expected rows

let test_multi_column_projection_in_schema_order () =
  let rows =
    project_users [ column_reference "name"; column_reference "email" ]
  in
  let expected =
    [
      [| Value.String "Alice"; Value.String "alice@example.com" |];
      [| Value.String "Bob"; Value.String "bob@example.com" |];
      [| Value.String "Carol"; Value.String "carol@example.com" |];
      [| Value.String "Dave"; Value.String "dave@example.com" |];
      [| Value.String "Eve"; Value.String "eve@example.com" |];
    ]
  in
  Alcotest.(check tuple_list_testable) "five two-column rows" expected rows

let test_projection_reorders_columns () =
  let rows =
    project_users [ column_reference "email"; column_reference "id" ]
  in
  let expected =
    [
      [| Value.String "alice@example.com"; Value.Int64 1L |];
      [| Value.String "bob@example.com"; Value.Int64 2L |];
      [| Value.String "carol@example.com"; Value.Int64 3L |];
      [| Value.String "dave@example.com"; Value.Int64 4L |];
      [| Value.String "eve@example.com"; Value.Int64 5L |];
    ]
  in
  Alcotest.(check tuple_list_testable) "rows in requested order" expected rows

let test_projection_of_non_leading_column () =
  (* "active" is at field index 3. A miscached position would pull the wrong
     tuple element. *)
  let rows = project_users [ column_reference "active" ] in
  let expected =
    [
      [| Value.Bool true |];
      [| Value.Bool false |];
      [| Value.Bool true |];
      [| Value.Bool true |];
      [| Value.Bool false |];
    ]
  in
  Alcotest.(check tuple_list_testable) "rows in active order" expected rows

let test_projection_accepts_qualified_column () =
  (* The qualified form should resolve to the same column as the bare name
     when there is no ambiguity. *)
  let rows =
    project_users [ qualified_column_reference ~qualifier:"users" ~name:"name" ]
  in
  let expected =
    [
      [| Value.String "Alice" |];
      [| Value.String "Bob" |];
      [| Value.String "Carol" |];
      [| Value.String "Dave" |];
      [| Value.String "Eve" |];
    ]
  in
  Alcotest.(check tuple_list_testable)
    "qualified projection yields the same rows" expected rows

let test_projected_schema_has_requested_fields () =
  let projected_schema, _project_tuple =
    Projection.resolve users_schema
      [ column_reference "email"; column_reference "id" ]
  in
  let field_names =
    List.map (fun (field : Schema.field) -> field.name) projected_schema.fields
  in
  Alcotest.(check (list string))
    "field names in requested order" [ "email"; "id" ] field_names;
  let field_kinds =
    List.map (fun (field : Schema.field) -> field.kind) projected_schema.fields
  in
  Alcotest.(check bool)
    "first field kind is String" true
    (field_kinds = [ Value.Kind.String; Value.Kind.Int64 ])

let test_projected_schema_preserves_qualifiers () =
  let projected_schema, _project_tuple =
    Projection.resolve users_schema [ column_reference "name" ]
  in
  let qualifiers =
    List.map
      (fun (field : Schema.field) -> field.qualifier)
      projected_schema.fields
  in
  Alcotest.(check (list (option string)))
    "qualifier is preserved" [ Some "users" ] qualifiers

let test_projected_schema_has_empty_primary_key () =
  let projected_schema, _project_tuple =
    Projection.resolve users_schema
      [ column_reference "id"; column_reference "name" ]
  in
  Alcotest.(check (list string))
    "primary_key is empty even when projection includes the input PK" []
    projected_schema.primary_key

let test_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Projection.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        Projection.resolve users_schema
          [ column_reference "name"; column_reference "unknown_col" ]
      in
      ())

let test_unknown_qualifier_raises () =
  Alcotest.check_raises "unknown qualified column"
    (Failure "Projection.resolve: unknown column \"orders.id\"") (fun () ->
      let _ =
        Projection.resolve users_schema
          [ qualified_column_reference ~qualifier:"orders" ~name:"id" ]
      in
      ())

(* Render a [Projection.t] to a string via [Projection.format]. *)
let format_to_string projection =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Projection.format formatter projection;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_single_bare_column () =
  Alcotest.(check string)
    "bare column renders as its name" "name"
    (format_to_string [ column_reference "name" ])

let test_format_single_qualified_column () =
  Alcotest.(check string)
    "qualified column renders as qualifier.name" "users.email"
    (format_to_string
       [ qualified_column_reference ~qualifier:"users" ~name:"email" ])

let test_format_multiple_columns_joined_by_commas () =
  Alcotest.(check string)
    "columns are comma-separated in input order" "id, name, active"
    (format_to_string
       [
         column_reference "id";
         column_reference "name";
         column_reference "active";
       ])

let test_format_empty_projection_renders_empty_string () =
  Alcotest.(check string)
    "empty list renders as the empty string" "" (format_to_string [])

let test_duplicate_column_raises () =
  Alcotest.check_raises "duplicate column"
    (Failure "Projection.resolve: duplicate column \"name\"") (fun () ->
      let _ =
        Projection.resolve users_schema
          [ column_reference "name"; column_reference "name" ]
      in
      ())

let () =
  Alcotest.run "projection"
    [
      ( "resolve",
        [
          Alcotest.test_case "single column projection" `Quick
            test_single_column_projection;
          Alcotest.test_case "multi-column projection in schema order" `Quick
            test_multi_column_projection_in_schema_order;
          Alcotest.test_case "projection reorders columns" `Quick
            test_projection_reorders_columns;
          Alcotest.test_case "projection of non-leading column" `Quick
            test_projection_of_non_leading_column;
          Alcotest.test_case "qualified column projects the same as bare name"
            `Quick test_projection_accepts_qualified_column;
          Alcotest.test_case "projected schema has requested fields" `Quick
            test_projected_schema_has_requested_fields;
          Alcotest.test_case "projected schema preserves qualifiers" `Quick
            test_projected_schema_preserves_qualifiers;
          Alcotest.test_case "projected schema has empty primary key" `Quick
            test_projected_schema_has_empty_primary_key;
        ] );
      ( "format",
        [
          Alcotest.test_case "single bare column renders as its name" `Quick
            test_format_single_bare_column;
          Alcotest.test_case "single qualified column renders as qualifier.name"
            `Quick test_format_single_qualified_column;
          Alcotest.test_case
            "multiple columns are comma-separated in input order" `Quick
            test_format_multiple_columns_joined_by_commas;
          Alcotest.test_case "empty projection renders as the empty string"
            `Quick test_format_empty_projection_renders_empty_string;
        ] );
      ( "errors",
        [
          Alcotest.test_case "unknown column raises naming the column" `Quick
            test_unknown_column_raises;
          Alcotest.test_case
            "qualified reference to a column not in this schema raises" `Quick
            test_unknown_qualifier_raises;
          Alcotest.test_case "duplicate column raises naming the column" `Quick
            test_duplicate_column_raises;
        ] );
    ]
