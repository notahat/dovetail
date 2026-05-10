(** Tests for [Translate]. *)

open Dovetail
open Test_helpers

let physical_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<physical>")) ( = )

let test_scan_lowers_to_full_scan () =
  let logical = Logical.Scan { table = "users" } in
  let physical = Translate.translate logical in
  Alcotest.(check physical_testable)
    "Scan -> FullScan"
    (Physical.FullScan { table = "users" })
    physical

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical = Logical.Scan { table = "users" } in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows from logical scan" expected_users_rows rows)

let id_equals_three : Predicate.t =
  Compare { left = Column "id"; op = Equal; right = Literal (Value.Int64 3L) }

let test_restrict_translates_to_filter () =
  let logical =
    Logical.Restrict
      { input = Logical.Scan { table = "users" }; predicate = id_equals_three }
  in
  let physical = Translate.translate logical in
  Alcotest.(check physical_testable)
    "Restrict -> Filter wrapping FullScan"
    (Physical.Filter
       {
         input = Physical.FullScan { table = "users" };
         predicate = id_equals_three;
       })
    physical

let test_restrict_pipeline_yields_filtered_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Restrict
          {
            input = Logical.Scan { table = "users" };
            predicate = id_equals_three;
          }
      in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "Carol's row from logical Restrict"
        [ List.nth expected_users_rows 2 ]
        rows)

let test_project_translates_to_physical_project () =
  let logical =
    Logical.Project
      {
        input = Logical.Scan { table = "users" };
        columns = [ "name"; "email" ];
      }
  in
  let physical = Translate.translate logical in
  Alcotest.(check physical_testable)
    "Project -> Project wrapping FullScan"
    (Physical.Project
       {
         input = Physical.FullScan { table = "users" };
         columns = [ "name"; "email" ];
       })
    physical

let test_project_pipeline_yields_projected_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let logical =
        Logical.Project
          {
            input = Logical.Scan { table = "users" };
            columns = [ "name"; "email" ];
          }
      in
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
        "five projected rows from logical Project" expected rows)

let () =
  Alcotest.run "translate"
    [
      ( "scan",
        [
          Alcotest.test_case "lowers Logical.Scan to Physical.FullScan" `Quick
            test_scan_lowers_to_full_scan;
          Alcotest.test_case
            "logical scan, translated and evaluated, yields fixture rows" `Quick
            test_pipeline_yields_fixture_rows;
        ] );
      ( "restrict",
        [
          Alcotest.test_case "lowers Logical.Restrict to Physical.Filter" `Quick
            test_restrict_translates_to_filter;
          Alcotest.test_case
            "logical Restrict, translated and evaluated, yields filtered rows"
            `Quick test_restrict_pipeline_yields_filtered_rows;
        ] );
      ( "project",
        [
          Alcotest.test_case "lowers Logical.Project to Physical.Project" `Quick
            test_project_translates_to_physical_project;
          Alcotest.test_case
            "logical Project, translated and evaluated, yields projected rows"
            `Quick test_project_pipeline_yields_projected_rows;
        ] );
    ]
