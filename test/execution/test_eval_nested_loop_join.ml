(** End-to-end tests for [Eval] on [Physical.NestedLoopJoin]. *)

open Test_helpers
module Value = Dovetail_core.Value
module Plan = Dovetail_plan

(* The matched (user, order) pairs that a join on
   [users.id = orders.user_id] should produce, built by concatenating the
   relevant fixture rows. The output order is left-outer-loop x right-inner,
   so users are visited in primary-key order; orders likewise within each
   user. The fixture has six matched pairs: Alice has two orders, Bob one,
   Carol two, Eve one (Dave has none). *)
let expected_matched_user_order_rows : Row.data list =
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

(* Always-true and always-false predicates over int64 literals. The
   predicate grammar has no bare boolean predicate, but [1 = 1] and
   [1 <> 1] do the same job and parse fine through the existing
   resolver. *)
let always_true_predicate =
  expression_compare
    ~left:(expression_literal (Value.Int64 1L))
    ~op:Equal
    ~right:(expression_literal (Value.Int64 1L))

let always_false_predicate =
  expression_compare
    ~left:(expression_literal (Value.Int64 1L))
    ~op:NotEqual
    ~right:(expression_literal (Value.Int64 1L))

let users_join_orders_on_id_predicate =
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

let nested_loop_join_plan predicate : Plan.Physical.t =
  NestedLoopJoin
    {
      left = FullScan { table = "users" };
      right = FullScan { table = "orders" };
      predicate;
    }

let test_nested_loop_join_yields_matched_pairs () =
  let _kind, rows =
    evaluate_against_fixture
      (nested_loop_join_plan users_join_orders_on_id_predicate)
  in
  Alcotest.(check row_list_testable)
    "six matched (user, order) pairs in left-outer-loop order"
    expected_matched_user_order_rows rows

let test_nested_loop_join_with_true_predicate_yields_full_cross () =
  let _kind, rows =
    evaluate_against_fixture (nested_loop_join_plan always_true_predicate)
  in
  Alcotest.(check int) "5 users x 6 orders = 30 rows" 30 (List.length rows)

let test_nested_loop_join_with_false_predicate_yields_no_rows () =
  let _kind, rows =
    evaluate_against_fixture (nested_loop_join_plan always_false_predicate)
  in
  Alcotest.(check row_list_testable) "no rows" [] rows

let test_nested_loop_join_kind_preserves_qualifiers () =
  let kind, _rows =
    evaluate_against_fixture
      (nested_loop_join_plan users_join_orders_on_id_predicate)
  in
  let qualified_field_names =
    List.map
      (fun (field : Row.field) ->
        match field.qualifier with
        | Some qualifier -> qualifier ^ "." ^ field.name
        | None -> field.name)
      kind.row_kind
  in
  Alcotest.(check (list string))
    "fields are users.* followed by orders.*"
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

let () =
  Alcotest.run "eval_nested_loop_join"
    [
      ( "nested loop join",
        [
          Alcotest.test_case
            "yields the matched (user, order) pairs in left-outer-loop order"
            `Quick test_nested_loop_join_yields_matched_pairs;
          Alcotest.test_case
            "with an always-true predicate yields the full cross product" `Quick
            test_nested_loop_join_with_true_predicate_yields_full_cross;
          Alcotest.test_case "with an always-false predicate yields no rows"
            `Quick test_nested_loop_join_with_false_predicate_yields_no_rows;
          Alcotest.test_case
            "result kind concatenates left then right with qualifiers \
             preserved"
            `Quick test_nested_loop_join_kind_preserves_qualifiers;
        ] );
    ]
