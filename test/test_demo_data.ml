(** Tests for [Demo_data]: surface-driven seeder used by the [--demo-data] REPL
    flag and the documentation doctest harness. The two assertions keep the
    contract small -- the demo script's row contents are exercised by
    [test/test_documentation.ml] via the doctested markdown, so re-asserting
    them here would duplicate that coverage. *)

open Dovetail
open Test_helpers

let test_populates_expected_tables () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Demo_data.run environment;
  Storage.with_read_transaction environment (fun transaction ->
      let has_table table_name =
        Option.is_some (Catalog.get environment transaction ~table_name)
      in
      Alcotest.(check bool) "users in catalog" true (has_table "users");
      Alcotest.(check bool) "orders in catalog" true (has_table "orders"))

let test_is_idempotent () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Demo_data.run environment;
  Demo_data.run environment;
  Storage.with_read_transaction environment (fun transaction ->
      let has_table table_name =
        Option.is_some (Catalog.get environment transaction ~table_name)
      in
      Alcotest.(check bool) "users still present" true (has_table "users");
      Alcotest.(check bool) "orders still present" true (has_table "orders"))

let () =
  Alcotest.run "demo_data"
    [
      ( "run",
        [
          Alcotest.test_case "populates the expected catalog tables" `Quick
            test_populates_expected_tables;
          Alcotest.test_case "is idempotent on a populated environment" `Quick
            test_is_idempotent;
        ] );
    ]
