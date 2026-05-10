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
        "five rows from AST" expected_users_rows rows)

let id_equals_three : Predicate.t =
  Compare { left = Column "id"; op = Equal; right = Literal (Value.Int64 3L) }

let test_restrict_lowers_to_logical_restrict () =
  let ast =
    Ast.Restrict
      { input = Ast.Relation_name "users"; predicate = id_equals_three }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Restrict -> Logical.Restrict wrapping Scan"
    (Logical.Restrict
       { input = Logical.Scan { table = "users" }; predicate = id_equals_three })
    logical

let test_restrict_pipeline_yields_filtered_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Restrict
          { input = Ast.Relation_name "users"; predicate = id_equals_three }
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "Carol's row from Ast.Restrict"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_project_lowers_to_logical_project () =
  let ast =
    Ast.Project
      { input = Ast.Relation_name "users"; columns = [ "name"; "email" ] }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "Ast.Project -> Logical.Project wrapping Scan"
    (Logical.Project
       {
         input = Logical.Scan { table = "users" };
         columns = [ "name"; "email" ];
       })
    logical

let test_project_pipeline_yields_projected_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        Ast.Project
          { input = Ast.Relation_name "users"; columns = [ "name"; "email" ] }
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      let expected =
        [
          [| Value.String "Alice"; Value.String "alice@example.com" |];
          [| Value.String "Bob"; Value.String "bob@example.com" |];
          [| Value.String "Carol"; Value.String "carol@example.com" |];
          [| Value.String "Dave"; Value.String "dave@example.com" |];
          [| Value.String "Eve"; Value.String "eve@example.com" |];
        ]
      in
      Alcotest.(check tuple_list_testable)
        "five projected rows from Ast.Project" expected rows)

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
      ( "restrict",
        [
          Alcotest.test_case "lowers Ast.Restrict to Logical.Restrict" `Quick
            test_restrict_lowers_to_logical_restrict;
          Alcotest.test_case
            "Ast.Restrict, lowered/translated/evaluated, yields filtered rows"
            `Quick test_restrict_pipeline_yields_filtered_rows;
        ] );
      ( "project",
        [
          Alcotest.test_case "lowers Ast.Project to Logical.Project" `Quick
            test_project_lowers_to_logical_project;
          Alcotest.test_case
            "Ast.Project, lowered/translated/evaluated, yields projected rows"
            `Quick test_project_pipeline_yields_projected_rows;
        ] );
    ]
