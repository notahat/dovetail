(** Tests for [Predicate]. *)

open Dovetail
open Test_helpers

(* The fixture's [users] schema, repeated here so the predicate tests are
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

(* The fixture's [orders] schema, repeated here for the same reason. *)
let orders_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    primary_key = [ "id" ];
  }

let orders_rows = expected_orders_rows

(* Build a [Compare] predicate with two literal-or-column terms. Local
   shorthand to keep the test bodies short. *)
let column name : Predicate.term = Column { qualifier = None; name }

let qualified_column ~qualifier ~name : Predicate.term =
  Column { qualifier = Some qualifier; name }

let literal value : Predicate.term = Literal value

let compare_predicate ~left ~op ~right : Predicate.t =
  Compare { left; op; right }

(* Apply [predicate] to every users fixture row and return the survivors. *)
let filter_users predicate =
  let evaluator = Predicate.resolve users_schema predicate in
  List.filter evaluator users_rows

(* Apply [predicate] to every orders fixture row and return the survivors. *)
let filter_orders predicate =
  let evaluator = Predicate.resolve orders_schema predicate in
  List.filter evaluator orders_rows

let test_equality_on_int64_column () =
  let matched =
    filter_users
      (compare_predicate ~left:(column "id") ~op:Equal
         ~right:(literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "one row with id = 3" 1 (List.length matched);
  Alcotest.(check tuple_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_equality_on_string_column () =
  let matched =
    filter_users
      (compare_predicate ~left:(column "name") ~op:Equal
         ~right:(literal (Value.String "Alice")))
  in
  Alcotest.(check tuple_list_testable)
    "row is Alice's"
    [ List.nth users_rows 0 ]
    matched

let test_equality_on_bool_column () =
  let matched =
    filter_users
      (compare_predicate ~left:(column "active") ~op:Equal
         ~right:(literal (Value.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length matched)

let test_inequality_on_int64_column () =
  let matched =
    filter_users
      (compare_predicate ~left:(column "id") ~op:NotEqual
         ~right:(literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length matched)

let test_predicate_on_non_first_column_uses_correct_position () =
  (* "active" is at field index 3. A miscached position would compare the
     wrong tuple element and either return wrong results or raise on type
     mismatch -- so this test pins the position-cache behaviour. *)
  let matched =
    filter_users
      (compare_predicate ~left:(column "active") ~op:Equal
         ~right:(literal (Value.Bool false)))
  in
  Alcotest.(check int) "two inactive rows" 2 (List.length matched)

let test_literal_on_left_and_column_on_right () =
  let matched =
    filter_users
      (compare_predicate ~left:(literal (Value.Int64 3L)) ~op:Equal
         ~right:(column "id"))
  in
  Alcotest.(check tuple_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_column_equals_column_on_users_finds_no_matches () =
  (* No user has [name = email]; the predicate should match zero rows. *)
  let matched =
    filter_users
      (compare_predicate ~left:(column "name") ~op:Equal ~right:(column "email"))
  in
  Alcotest.(check tuple_list_testable) "no rows" [] matched

let test_column_equals_column_on_orders_finds_self_referential_rows () =
  (* In the orders fixture, only [(1, 1, ...)] has [id = user_id]. *)
  let matched =
    filter_orders
      (compare_predicate ~left:(column "id") ~op:Equal ~right:(column "user_id"))
  in
  Alcotest.(check tuple_list_testable)
    "single row where id = user_id"
    [ List.nth orders_rows 0 ]
    matched

let test_column_inequality_on_orders () =
  (* Five orders rows have [id <> user_id]; only the first has them equal. *)
  let matched =
    filter_orders
      (compare_predicate ~left:(column "id") ~op:NotEqual
         ~right:(column "user_id"))
  in
  Alcotest.(check int) "five rows with id <> user_id" 5 (List.length matched)

let test_qualified_column_resolves_identically_to_unqualified () =
  (* Single-relation queries should keep working when the user qualifies the
     column reference. Same row count, same result. *)
  let matched =
    filter_users
      (compare_predicate
         ~left:(qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal ~right:(literal (Value.Int64 3L)))
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row from qualified id"
    [ List.nth users_rows 2 ]
    matched

let test_unknown_qualifier_raises () =
  Alcotest.check_raises "unknown qualified column"
    (Failure "Predicate.resolve: unknown column \"orders.id\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (compare_predicate
             ~left:(qualified_column ~qualifier:"orders" ~name:"id")
             ~op:Equal ~right:(literal (Value.Int64 3L)))
      in
      ())

let test_unknown_column_on_left_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (compare_predicate ~left:(column "unknown_col") ~op:Equal
             ~right:(literal (Value.Int64 3L)))
      in
      ())

let test_unknown_column_on_right_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Predicate.resolve: unknown column \"unknown_col\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (compare_predicate ~left:(column "id") ~op:Equal
             ~right:(column "unknown_col"))
      in
      ())

let test_type_mismatch_column_vs_literal_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Predicate.resolve: type mismatch: column \"name\" is String, literal \
        Int64 is Int64") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (compare_predicate ~left:(column "name") ~op:Equal
             ~right:(literal (Value.Int64 1L)))
      in
      ())

let test_type_mismatch_column_vs_column_raises () =
  Alcotest.check_raises "type mismatch column vs column"
    (Failure
       "Predicate.resolve: type mismatch: column \"id\" is Int64, column \
        \"name\" is String") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Predicate.resolve users_schema
          (compare_predicate ~left:(column "id") ~op:Equal
             ~right:(column "name"))
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
          Alcotest.test_case "literal on left and column on right" `Quick
            test_literal_on_left_and_column_on_right;
          Alcotest.test_case
            "column = column on users finds no rows where name = email" `Quick
            test_column_equals_column_on_users_finds_no_matches;
          Alcotest.test_case
            "column = column on orders finds the self-referential row" `Quick
            test_column_equals_column_on_orders_finds_self_referential_rows;
          Alcotest.test_case "column <> column on orders" `Quick
            test_column_inequality_on_orders;
          Alcotest.test_case
            "qualified column reference resolves identically to unqualified"
            `Quick test_qualified_column_resolves_identically_to_unqualified;
        ] );
      ( "errors",
        [
          Alcotest.test_case "unknown column on left raises naming the column"
            `Quick test_unknown_column_on_left_raises;
          Alcotest.test_case "unknown column on right raises naming the column"
            `Quick test_unknown_column_on_right_raises;
          Alcotest.test_case
            "type mismatch column vs literal raises naming both sides" `Quick
            test_type_mismatch_column_vs_literal_raises;
          Alcotest.test_case
            "type mismatch column vs column raises naming both sides" `Quick
            test_type_mismatch_column_vs_column_raises;
          Alcotest.test_case
            "qualified reference to a column not in this schema raises" `Quick
            test_unknown_qualifier_raises;
        ] );
    ]
