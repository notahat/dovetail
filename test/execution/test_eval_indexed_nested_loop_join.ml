(** End-to-end tests for [Eval] on [Physical.IndexedNestedLoopJoin]. *)

open Dovetail_execution
open Test_helpers
module Schema = Dovetail_core.Schema
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* The matched (user, order) pairs that the canonical indexed join --
   stream [orders], probe [users] by [orders.user_id] -- should produce.
   Streaming [orders] means visiting orders in primary-key order; each
   probe is at most one row. Six orders, all with a matching user_id. *)
let expected_user_then_order_rows : Row.data list =
  let user index = List.nth expected_users_rows index in
  let order index = List.nth expected_orders_rows index in
  let pair user_index order_index =
    Array.append (user user_index) (order order_index)
  in
  [
    pair 0 0;
    (* Alice + Coffee *)
    pair 0 1;
    (* Alice + Bagel *)
    pair 1 2;
    (* Bob + Tea *)
    pair 2 3;
    (* Carol + Sandwich *)
    pair 2 4;
    (* Carol + Cake *)
    pair 4 5;
    (* Eve + Cookie *)
  ]

(* The same matched pairs as above, but with [orders] columns first and
   [users] columns second. Used for the [inner_position = Right] case. *)
let expected_order_then_user_rows : Row.data list =
  let user index = List.nth expected_users_rows index in
  let order index = List.nth expected_orders_rows index in
  let pair order_index user_index =
    Array.append (order order_index) (user user_index)
  in
  [ pair 0 0; pair 1 0; pair 2 1; pair 3 2; pair 4 2; pair 5 4 ]

let orders_user_id_column =
  qualified_column_reference ~qualifier:"orders" ~name:"user_id"

let orders_id_column = qualified_column_reference ~qualifier:"orders" ~name:"id"

let canonical_indexed_join_plan inner_position : Plan.Physical.t =
  IndexedNestedLoopJoin
    {
      outer = FullScan { table = "orders" };
      inner_table = "users";
      outer_key_column = orders_user_id_column;
      inner_position;
    }

let test_indexed_join_left_yields_matched_pairs () =
  let _schema, rows =
    evaluate_against_fixture (canonical_indexed_join_plan `Left)
  in
  Alcotest.(check tuple_list_testable)
    "six matched (user, order) pairs in outer (orders) order"
    expected_user_then_order_rows rows

let test_indexed_join_left_schema_has_inner_then_outer_fields () =
  let kind, _rows =
    evaluate_against_fixture (canonical_indexed_join_plan `Left)
  in
  let qualified_field_names = List.map Row.format_field_name kind.row_kind in
  Alcotest.(check (list string))
    "fields are users.* (inner) followed by orders.* (outer)"
    [
      "users.id";
      "users.name";
      "users.email";
      "users.active";
      "orders.id";
      "orders.user_id";
      "orders.description";
      "orders.amount";
    ]
    qualified_field_names;
  Alcotest.(check int)
    "no refinements for derived relations" 0
    (List.length kind.refinements)

let test_indexed_join_right_yields_matched_pairs () =
  let _schema, rows =
    evaluate_against_fixture (canonical_indexed_join_plan `Right)
  in
  Alcotest.(check tuple_list_testable)
    "six matched (order, user) pairs in outer (orders) order"
    expected_order_then_user_rows rows

let test_indexed_join_right_schema_has_outer_then_inner_fields () =
  let kind, _rows =
    evaluate_against_fixture (canonical_indexed_join_plan `Right)
  in
  let qualified_field_names = List.map Row.format_field_name kind.row_kind in
  Alcotest.(check (list string))
    "fields are orders.* (outer) followed by users.* (inner)"
    [
      "orders.id";
      "orders.user_id";
      "orders.description";
      "orders.amount";
      "users.id";
      "users.name";
      "users.email";
      "users.active";
    ]
    qualified_field_names

(* When the probe key has no match in the inner, the outer tuple is
   dropped silently. The fixture's natural join doesn't exercise this --
   every order's user_id resolves to a real user -- so we synthesise a
   plan that probes [users] by [orders.id]. Orders has ids 1..6, users
   has ids 1..5, so order 6 (Cookie) misses and the result has five
   rows instead of six. *)
let test_indexed_join_drops_outer_tuples_whose_probe_misses () =
  let plan : Plan.Physical.t =
    IndexedNestedLoopJoin
      {
        outer = FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column = orders_id_column;
        inner_position = `Left;
      }
  in
  let _schema, rows = evaluate_against_fixture plan in
  Alcotest.(check int) "five rows -- order 6 misses" 5 (List.length rows)

let test_indexed_join_raises_when_outer_key_column_is_not_int64 () =
  let plan : Plan.Physical.t =
    IndexedNestedLoopJoin
      {
        outer = FullScan { table = "orders" };
        inner_table = "users";
        outer_key_column =
          qualified_column_reference ~qualifier:"orders" ~name:"description";
        inner_position = `Left;
      }
  in
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.check_raises "non-Int64 outer key column"
        (Failure
           "Eval: IndexedNestedLoopJoin requires Int64 outer key column, got \
            String for \"orders.description\"") (fun () ->
          Eval.eval environment transaction plan (fun _relation -> ())))

let () =
  Alcotest.run "eval_indexed_nested_loop_join"
    [
      ( "indexed nested loop join",
        [
          Alcotest.test_case
            "Left inner_position yields inner.fields @ outer.fields rows" `Quick
            test_indexed_join_left_yields_matched_pairs;
          Alcotest.test_case
            "Left inner_position schema is users.* then orders.*" `Quick
            test_indexed_join_left_schema_has_inner_then_outer_fields;
          Alcotest.test_case
            "Right inner_position yields outer.fields @ inner.fields rows"
            `Quick test_indexed_join_right_yields_matched_pairs;
          Alcotest.test_case
            "Right inner_position schema is orders.* then users.*" `Quick
            test_indexed_join_right_schema_has_outer_then_inner_fields;
          Alcotest.test_case "outer tuples with no matching inner row drop out"
            `Quick test_indexed_join_drops_outer_tuples_whose_probe_misses;
          Alcotest.test_case "raises when the outer key column is not Int64"
            `Quick test_indexed_join_raises_when_outer_key_column_is_not_int64;
        ] );
    ]
