(** End-to-end tests for [Eval] on [Physical.CrossProduct]. *)

open Test_helpers
module Scalar = Dovetail_core.Scalar
module Plan = Dovetail_plan

let users_cross_orders_plan : Plan.Physical.t =
  CrossProduct
    {
      left = FullScan { table = "users" };
      right = FullScan { table = "orders" };
    }

let test_cross_product_yields_thirty_rows () =
  let _kind, rows = evaluate_against_fixture users_cross_orders_plan in
  Alcotest.(check int) "5 users x 6 orders = 30 rows" 30 (List.length rows)

let test_cross_product_kind_concatenates_with_qualifiers_preserved () =
  let kind, _rows = evaluate_against_fixture users_cross_orders_plan in
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

let test_cross_product_then_filter_yields_matched_pairs () =
  (* The plan: users x orders, filtered to rows where users.id = orders.user_id.
     The orders fixture has six rows that point at users 1, 1, 2, 3, 3, 5 -- so
     we expect six matched pairs. *)
  let plan : Plan.Physical.t =
    Filter
      {
        input = users_cross_orders_plan;
        predicate =
          expression_compare
            ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
            ~op:Equal
            ~right:
              (expression_qualified_column ~qualifier:"orders" ~name:"user_id");
      }
  in
  let _kind, rows = evaluate_against_fixture plan in
  Alcotest.(check int) "six matched (user, order) pairs" 6 (List.length rows)

let () =
  Alcotest.run "eval_cross_product"
    [
      ( "cross product",
        [
          Alcotest.test_case
            "yields one row per (left, right) pair from the inputs" `Quick
            test_cross_product_yields_thirty_rows;
          Alcotest.test_case
            "result kind concatenates left then right with qualifiers preserved"
            `Quick
            test_cross_product_kind_concatenates_with_qualifiers_preserved;
          Alcotest.test_case
            "filter on the cross product yields the matched (user, order) pairs"
            `Quick test_cross_product_then_filter_yields_matched_pairs;
        ] );
    ]
