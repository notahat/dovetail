(** Tests for [Predicate]. *)

open Dovetail
open Test_helpers

(* The fixture's [users] schema, repeated here so the predicate tests are
   self-contained and don't need to spin up an LMDB environment. *)
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

let users_rows = expected_users_rows

(* Apply [predicate] to every fixture row and return the survivors. *)
let filter_users predicate =
  let evaluator = Predicate.resolve users_schema predicate in
  List.filter evaluator users_rows

let test_equality_on_int64_column () =
  let matched =
    filter_users
      (Predicate.Compare
         { column_name = "id"; op = Equal; literal = Value.Int64 3L })
  in
  Alcotest.(check int) "one row with id = 3" 1 (List.length matched);
  Alcotest.(check tuple_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_equality_on_string_column () =
  let matched =
    filter_users
      (Predicate.Compare
         { column_name = "name"; op = Equal; literal = Value.String "Alice" })
  in
  Alcotest.(check tuple_list_testable)
    "row is Alice's"
    [ List.nth users_rows 0 ]
    matched

let test_equality_on_bool_column () =
  let matched =
    filter_users
      (Predicate.Compare
         { column_name = "active"; op = Equal; literal = Value.Bool true })
  in
  Alcotest.(check int) "three active rows" 3 (List.length matched)

let test_inequality_on_int64_column () =
  let matched =
    filter_users
      (Predicate.Compare
         { column_name = "id"; op = NotEqual; literal = Value.Int64 3L })
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length matched)

let test_predicate_on_non_first_column_uses_correct_position () =
  (* "active" is at field index 3. A miscached position would compare the
     wrong tuple element and either return wrong results or raise on type
     mismatch -- so this test pins the position-cache behaviour. *)
  let matched =
    filter_users
      (Predicate.Compare
         { column_name = "active"; op = Equal; literal = Value.Bool false })
  in
  Alcotest.(check int) "two inactive rows" 2 (List.length matched)

let test_unknown_column_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (Predicate.Compare
             {
               column_name = "unknown_col";
               op = Equal;
               literal = Value.Int64 3L;
             })
      in
      ())

let test_type_mismatch_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Predicate.resolve: type mismatch: column \"name\" is String, literal \
        is Int64") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (Predicate.Compare
             { column_name = "name"; op = Equal; literal = Value.Int64 1L })
      in
      ())

let () =
  Alcotest.run "predicate"
    [
      ( "compare",
        [
          Alcotest.test_case "equality on int64 column" `Quick
            test_equality_on_int64_column;
          Alcotest.test_case "equality on string column" `Quick
            test_equality_on_string_column;
          Alcotest.test_case "equality on bool column" `Quick
            test_equality_on_bool_column;
          Alcotest.test_case "inequality on int64 column" `Quick
            test_inequality_on_int64_column;
          Alcotest.test_case
            "predicate on non-first column uses correct position" `Quick
            test_predicate_on_non_first_column_uses_correct_position;
        ] );
      ( "errors",
        [
          Alcotest.test_case "unknown column raises naming the column" `Quick
            test_unknown_column_raises;
          Alcotest.test_case
            "type mismatch raises naming column and literal kinds" `Quick
            test_type_mismatch_raises;
        ] );
    ]
