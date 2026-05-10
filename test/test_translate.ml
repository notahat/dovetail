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
    ]
