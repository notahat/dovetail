(** Tests for [Lower]. *)

open Dovetail
open Test_helpers

let logical_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical>")) ( = )

let test_relation_name_lowers_to_scan () =
  let ast = Ast.Relation_name "users" in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Relation_name -> Scan"
    (Logical.Scan { table = "users" })
    logical

let expected_rows : Schema.tuple list =
  [
    [|
      Value.Int64 1L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 2L;
      Value.String "Bob";
      Value.String "bob@example.com";
      Value.Bool false;
    |];
    [|
      Value.Int64 3L;
      Value.String "Carol";
      Value.String "carol@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 4L;
      Value.String "Dave";
      Value.String "dave@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 5L;
      Value.String "Eve";
      Value.String "eve@example.com";
      Value.Bool false;
    |];
  ]

let tuple_list_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<tuples>")) ( = )

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast = Ast.Relation_name "users" in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows from AST" expected_rows rows)

let () =
  Alcotest.run "lower"
    [
      ( "relation_name",
        [
          Alcotest.test_case "lowers Ast.Relation_name to Logical.Scan" `Quick
            test_relation_name_lowers_to_scan;
          Alcotest.test_case
            "AST, lowered, translated and evaluated, yields fixture rows" `Quick
            test_pipeline_yields_fixture_rows;
        ] );
    ]
