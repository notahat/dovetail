(** End-to-end tests for [Eval]: populate the fixture and read it back through
    the physical IR. *)

open Dovetail
open Test_helpers

let test_full_scan_yields_fixture_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let relation =
        Eval.eval environment transaction
          (Physical.FullScan { table = "users" })
      in
      Alcotest.(check string)
        "schema primary key" "id"
        (String.concat "," relation.schema.primary_key);
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows in primary-key order" expected_users_rows rows)

let test_full_scan_raises_for_missing_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.check_raises "missing table"
        (Failure "Eval: unknown table \"orders\"") (fun () ->
          let _ =
            Eval.eval environment transaction
              (Physical.FullScan { table = "orders" })
          in
          ()))

(* Build a Filter wrapping a FullScan over the users fixture, evaluate it,
   and return the resulting tuples. *)
let evaluate_users_filter predicate =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let plan =
        Physical.Filter
          { input = Physical.FullScan { table = "users" }; predicate }
      in
      let relation = Eval.eval environment transaction plan in
      List.of_seq relation.tuples)

let test_filter_equality_on_int64_yields_one_row () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "id"; op = Equal; literal = Value.Int64 3L })
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row"
    [ List.nth expected_users_rows 2 ]
    rows

let test_filter_equality_on_string_yields_one_row () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "name"; op = Equal; literal = Value.String "Alice" })
  in
  Alcotest.(check tuple_list_testable)
    "Alice's row"
    [ List.nth expected_users_rows 0 ]
    rows

let test_filter_equality_on_bool_yields_active_rows () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "active"; op = Equal; literal = Value.Bool true })
  in
  Alcotest.(check int) "three active rows" 3 (List.length rows)

let test_filter_inequality_yields_complement () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "id"; op = NotEqual; literal = Value.Int64 3L })
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length rows)

let test_filter_matches_all_rows () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "id"; op = NotEqual; literal = Value.Int64 999L })
  in
  Alcotest.(check tuple_list_testable)
    "all five fixture rows" expected_users_rows rows

let test_filter_matches_zero_rows () =
  let rows =
    evaluate_users_filter
      (Predicate.Compare
         { column_name = "id"; op = Equal; literal = Value.Int64 999L })
  in
  Alcotest.(check tuple_list_testable) "no rows" [] rows

let test_filter_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let _ =
        evaluate_users_filter
          (Predicate.Compare
             {
               column_name = "unknown_col";
               op = Equal;
               literal = Value.Int64 3L;
             })
      in
      ())

let test_filter_type_mismatch_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Predicate.resolve: type mismatch: column \"name\" is String, literal \
        is Int64") (fun () ->
      let _ =
        evaluate_users_filter
          (Predicate.Compare
             { column_name = "name"; op = Equal; literal = Value.Int64 1L })
      in
      ())

let () =
  Alcotest.run "eval"
    [
      ( "full scan",
        [
          Alcotest.test_case "yields the five fixture rows in primary-key order"
            `Quick test_full_scan_yields_fixture_rows;
          Alcotest.test_case "raises when the table is missing from the catalog"
            `Quick test_full_scan_raises_for_missing_table;
        ] );
      ( "filter",
        [
          Alcotest.test_case "equality on int64 column yields the matching row"
            `Quick test_filter_equality_on_int64_yields_one_row;
          Alcotest.test_case "equality on string column yields the matching row"
            `Quick test_filter_equality_on_string_yields_one_row;
          Alcotest.test_case "equality on bool column yields all active rows"
            `Quick test_filter_equality_on_bool_yields_active_rows;
          Alcotest.test_case "inequality yields the complement" `Quick
            test_filter_inequality_yields_complement;
          Alcotest.test_case "predicate that matches every row yields them all"
            `Quick test_filter_matches_all_rows;
          Alcotest.test_case "predicate that matches no row yields empty" `Quick
            test_filter_matches_zero_rows;
          Alcotest.test_case
            "unknown column raises before any tuples are pulled" `Quick
            test_filter_unknown_column_raises;
          Alcotest.test_case "type mismatch raises before any tuples are pulled"
            `Quick test_filter_type_mismatch_raises;
        ] );
    ]
