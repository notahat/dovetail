(** Tests for [Expression]. *)

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

(* Apply [predicate] to every users fixture row and return the survivors. *)
let filter_users predicate =
  let evaluator = Expression.resolve users_schema predicate in
  List.filter evaluator users_rows

(* Apply [predicate] to every orders fixture row and return the survivors. *)
let filter_orders predicate =
  let evaluator = Expression.resolve orders_schema predicate in
  List.filter evaluator orders_rows

let test_equality_on_int64_column () =
  let matched =
    filter_users
      (predicate_compare ~left:(predicate_column "id") ~op:Equal
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "one row with id = 3" 1 (List.length matched);
  Alcotest.(check tuple_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_equality_on_string_column () =
  let matched =
    filter_users
      (predicate_compare ~left:(predicate_column "name") ~op:Equal
         ~right:(predicate_literal (Value.String "Alice")))
  in
  Alcotest.(check tuple_list_testable)
    "row is Alice's"
    [ List.nth users_rows 0 ]
    matched

let test_equality_on_bool_column () =
  let matched =
    filter_users
      (predicate_compare
         ~left:(predicate_column "active")
         ~op:Equal
         ~right:(predicate_literal (Value.Bool true)))
  in
  Alcotest.(check int) "three active rows" 3 (List.length matched)

let test_inequality_on_int64_column () =
  let matched =
    filter_users
      (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check int) "four rows with id <> 3" 4 (List.length matched)

let test_predicate_on_non_first_column_uses_correct_position () =
  (* "active" is at field index 3. A miscached position would compare the
     wrong tuple element and either return wrong results or raise on type
     mismatch -- so this test pins the position-cache behaviour. *)
  let matched =
    filter_users
      (predicate_compare
         ~left:(predicate_column "active")
         ~op:Equal
         ~right:(predicate_literal (Value.Bool false)))
  in
  Alcotest.(check int) "two inactive rows" 2 (List.length matched)

let test_literal_on_left_and_column_on_right () =
  let matched =
    filter_users
      (predicate_compare
         ~left:(predicate_literal (Value.Int64 3L))
         ~op:Equal ~right:(predicate_column "id"))
  in
  Alcotest.(check tuple_list_testable)
    "row is Carol's"
    [ List.nth users_rows 2 ]
    matched

let test_column_equals_column_on_users_finds_no_matches () =
  (* No user has [name = email]; the predicate should match zero rows. *)
  let matched =
    filter_users
      (predicate_compare ~left:(predicate_column "name") ~op:Equal
         ~right:(predicate_column "email"))
  in
  Alcotest.(check tuple_list_testable) "no rows" [] matched

let test_column_equals_column_on_orders_finds_self_referential_rows () =
  (* In the orders fixture, only [(1, 1, ...)] has [id = user_id]. *)
  let matched =
    filter_orders
      (predicate_compare ~left:(predicate_column "id") ~op:Equal
         ~right:(predicate_column "user_id"))
  in
  Alcotest.(check tuple_list_testable)
    "single row where id = user_id"
    [ List.nth orders_rows 0 ]
    matched

let test_column_inequality_on_orders () =
  (* Five orders rows have [id <> user_id]; only the first has them equal. *)
  let matched =
    filter_orders
      (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
         ~right:(predicate_column "user_id"))
  in
  Alcotest.(check int) "five rows with id <> user_id" 5 (List.length matched)

let test_bare_bool_column_resolves_as_predicate () =
  (* Slice 7 step 2 generalises the IR so a standalone column is a valid
     expression. A Bool-kinded column resolves directly as a predicate;
     each row's verdict equals its [active] flag. *)
  let evaluator = Expression.resolve users_schema (predicate_column "active") in
  let verdicts = List.map evaluator users_rows in
  Alcotest.(check (list bool))
    "predicate verdict tracks the active column"
    [ true; false; true; true; false ]
    verdicts

let test_bare_bool_literal_resolves_as_predicate () =
  (* A standalone Bool literal is a valid (degenerate) predicate; the
     verdict is constant across all rows. *)
  let always_true =
    Expression.resolve users_schema (predicate_literal (Value.Bool true))
  in
  Alcotest.(check bool)
    "true literal is true for every row" true
    (always_true (List.hd users_rows))

let test_qualified_column_resolves_identically_to_unqualified () =
  (* Single-relation queries should keep working when the user qualifies the
     column reference. Same row count, same result. *)
  let matched =
    filter_users
      (predicate_compare
         ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check tuple_list_testable)
    "Carol's row from qualified id"
    [ List.nth users_rows 2 ]
    matched

let test_unknown_qualifier_raises () =
  Alcotest.check_raises "unknown qualified column"
    (Failure "Expression.resolve: unknown column \"orders.id\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_compare
             ~left:(predicate_qualified_column ~qualifier:"orders" ~name:"id")
             ~op:Equal
             ~right:(predicate_literal (Value.Int64 3L)))
      in
      ())

let test_unknown_column_on_left_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Expression.resolve: unknown column \"unknown_col\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_compare
             ~left:(predicate_column "unknown_col")
             ~op:Equal
             ~right:(predicate_literal (Value.Int64 3L)))
      in
      ())

let test_unknown_column_on_right_raises () =
  Alcotest.check_raises "unknown column"
    (Failure "Expression.resolve: unknown column \"unknown_col\"") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_compare ~left:(predicate_column "id") ~op:Equal
             ~right:(predicate_column "unknown_col"))
      in
      ())

let test_type_mismatch_column_vs_literal_raises () =
  Alcotest.check_raises "type mismatch"
    (Failure
       "Expression.resolve: type mismatch: column \"name\" is String, literal \
        Int64 is Int64") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_compare ~left:(predicate_column "name") ~op:Equal
             ~right:(predicate_literal (Value.Int64 1L)))
      in
      ())

let test_non_bool_predicate_raises () =
  (* The top-level kind check fires when a standalone non-Bool expression
     reaches a predicate position. Today the only way to construct one is
     to pass a non-Bool column or literal to [resolve]. *)
  Alcotest.check_raises "non-Bool top-level expression"
    (Failure "Expression.resolve: predicate position requires Bool, got Int64")
    (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema (predicate_column "id")
      in
      ())

let test_non_bool_literal_predicate_raises () =
  Alcotest.check_raises "non-Bool literal predicate"
    (Failure "Expression.resolve: predicate position requires Bool, got String")
    (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_literal (Value.String "hello"))
      in
      ())

let test_type_mismatch_column_vs_column_raises () =
  Alcotest.check_raises "type mismatch column vs column"
    (Failure
       "Expression.resolve: type mismatch: column \"id\" is Int64, column \
        \"name\" is String") (fun () ->
      let (_ : Schema.tuple -> bool) =
        Expression.resolve users_schema
          (predicate_compare ~left:(predicate_column "id") ~op:Equal
             ~right:(predicate_column "name"))
      in
      ())

let format_to_string predicate =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Expression.format formatter predicate;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_column_equals_int64_literal () =
  let rendered =
    format_to_string
      (predicate_compare ~left:(predicate_column "id") ~op:Equal
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id = 3" "id = 3" rendered

let test_format_column_equals_string_literal_quotes_string () =
  let rendered =
    format_to_string
      (predicate_compare ~left:(predicate_column "name") ~op:Equal
         ~right:(predicate_literal (Value.String "Alice")))
  in
  Alcotest.(check string)
    "string literal is double-quoted" "name = \"Alice\"" rendered

let test_format_column_equals_bool_literal () =
  let rendered =
    format_to_string
      (predicate_compare
         ~left:(predicate_column "active")
         ~op:Equal
         ~right:(predicate_literal (Value.Bool true)))
  in
  Alcotest.(check string) "bool literal as keyword" "active = true" rendered

let test_format_inequality_uses_angle_brackets () =
  let rendered =
    format_to_string
      (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
         ~right:(predicate_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id <> 3" "id <> 3" rendered

let test_format_bare_column_renders_as_column_name () =
  let rendered = format_to_string (predicate_column "active") in
  Alcotest.(check string) "bare column renders as its name" "active" rendered

let test_format_bare_literal_renders_as_literal () =
  let rendered = format_to_string (predicate_literal (Value.Bool true)) in
  Alcotest.(check string)
    "bare bool literal renders as the keyword" "true" rendered

let test_format_qualified_columns_use_dot_form () =
  let rendered =
    format_to_string
      (predicate_compare
         ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal
         ~right:(predicate_qualified_column ~qualifier:"orders" ~name:"user_id"))
  in
  Alcotest.(check string)
    "qualified column references render in dotted form"
    "users.id = orders.user_id" rendered

let () =
  Alcotest.run "expression"
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
          Alcotest.test_case "bare bool column resolves as a predicate" `Quick
            test_bare_bool_column_resolves_as_predicate;
          Alcotest.test_case "bare bool literal resolves as a predicate" `Quick
            test_bare_bool_literal_resolves_as_predicate;
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
          Alcotest.test_case "non-Bool column at the predicate position raises"
            `Quick test_non_bool_predicate_raises;
          Alcotest.test_case "non-Bool literal at the predicate position raises"
            `Quick test_non_bool_literal_predicate_raises;
        ] );
      ( "format",
        [
          Alcotest.test_case "column = int64 literal" `Quick
            test_format_column_equals_int64_literal;
          Alcotest.test_case "column = string literal quotes the string" `Quick
            test_format_column_equals_string_literal_quotes_string;
          Alcotest.test_case "column = bool literal" `Quick
            test_format_column_equals_bool_literal;
          Alcotest.test_case "inequality renders with <>" `Quick
            test_format_inequality_uses_angle_brackets;
          Alcotest.test_case "qualified columns render in dotted form" `Quick
            test_format_qualified_columns_use_dot_form;
          Alcotest.test_case "bare column renders as the column name" `Quick
            test_format_bare_column_renders_as_column_name;
          Alcotest.test_case "bare literal renders as the literal" `Quick
            test_format_bare_literal_renders_as_literal;
        ] );
    ]
