(** End-to-end tests for [Eval] on [Physical.CrossProduct]. *)

open Test_helpers
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
module Plan = Dovetail_plan

let users_cross_orders_plan : Plan.Physical.t =
  CrossProduct
    {
      left = FullScan { table = "users" };
      right = FullScan { table = "orders" };
    }

let test_cross_product_yields_thirty_rows () =
  let _schema, rows = evaluate_against_fixture users_cross_orders_plan in
  Alcotest.(check int) "5 users x 6 orders = 30 rows" 30 (List.length rows)

let test_cross_product_schema_concatenates_with_qualifiers_preserved () =
  let schema, _rows = evaluate_against_fixture users_cross_orders_plan in
  let qualified_field_names =
    List.map
      (fun (field : Schema.field) ->
        match field.qualifier with
        | Some qualifier -> qualifier ^ "." ^ field.name
        | None -> field.name)
      schema.fields
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
  Alcotest.(check (list string))
    "primary_key is empty for derived relations" [] schema.primary_key

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
  let _schema, rows = evaluate_against_fixture plan in
  Alcotest.(check int) "six matched (user, order) pairs" 6 (List.length rows)

let test_cross_product_with_ambiguous_unqualified_filter_raises () =
  (* Both inputs have an [id] column, so an unqualified [id = 3] predicate
     can't pick one. Resolution should fail with the ambiguity message. *)
  let plan : Plan.Physical.t =
    Filter
      {
        input = users_cross_orders_plan;
        predicate =
          expression_compare ~left:(expression_column "id") ~op:Equal
            ~right:(expression_literal (Value.Int64 3L));
      }
  in
  Alcotest.check_raises "ambiguous unqualified column"
    (Failure
       "Expression.resolve: ambiguous column reference \"id\": matches \
        \"users.id\" and \"orders.id\"") (fun () ->
      let _ = evaluate_against_fixture plan in
      ())

let () =
  Alcotest.run "eval_cross_product"
    [
      ( "cross product",
        [
          Alcotest.test_case
            "yields one row per (left, right) pair from the inputs" `Quick
            test_cross_product_yields_thirty_rows;
          Alcotest.test_case
            "result schema concatenates left then right with qualifiers \
             preserved"
            `Quick
            test_cross_product_schema_concatenates_with_qualifiers_preserved;
          Alcotest.test_case
            "filter on the cross product yields the matched (user, order) pairs"
            `Quick test_cross_product_then_filter_yields_matched_pairs;
          Alcotest.test_case
            "filter using an unqualified column that matches both inputs \
             raises with the ambiguity message"
            `Quick test_cross_product_with_ambiguous_unqualified_filter_raises;
        ] );
    ]
