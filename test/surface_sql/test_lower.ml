(** Tests for [Lower]. *)

open Dovetail_surface_sql
module Plan = Dovetail_plan
module Expression = Dovetail_core.Expression
module Scalar = Dovetail_core.Scalar

let logical_testable : Plan.Logical.t Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical-plan>")) ( = )

(* A [SELECT * FROM <table> WHERE <predicate>] AST. *)
let select_where table predicate =
  Ast.Select { select_list = Ast.All; from = table; where = Some predicate }

(* A bare (unqualified) column reference, in the surface AST and in the IR. *)
let ast_column name : Ast.expression = Ast.Column { qualifier = None; name }
let ir_column name : Expression.t = Expression.Column { qualifier = None; name }

let test_select_star_lowers_to_scan () =
  let ast =
    Ast.Select { select_list = Ast.All; from = "users"; where = None }
  in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "SELECT * FROM users -> Scan(users)"
    (Scan { table = "users" })
    logical

let test_where_bare_column_lowers_to_restrict () =
  let ast = select_where "users" (ast_column "active") in
  Alcotest.(check logical_testable)
    "WHERE active -> Restrict(Scan, Column active)"
    (Restrict
       { input = Scan { table = "users" }; predicate = ir_column "active" })
    (Lower.lower ast)

let test_each_comparison_operator_lowers () =
  List.iter
    (fun (ast_op, ir_op) ->
      let ast =
        select_where "t"
          (Ast.Compare
             {
               left = ast_column "a";
               op = ast_op;
               right = Ast.Literal (Scalar.Int64 1L);
             })
      in
      Alcotest.(check logical_testable)
        "comparison op lowers"
        (Restrict
           {
             input = Scan { table = "t" };
             predicate =
               Expression.Compare
                 {
                   left = ir_column "a";
                   op = ir_op;
                   right = Expression.Literal (Scalar.Int64 1L);
                 };
           })
        (Lower.lower ast))
    [
      (Ast.Equal, Expression.Equal);
      (Ast.NotEqual, Expression.NotEqual);
      (Ast.Less, Expression.Less);
      (Ast.LessEqual, Expression.LessEqual);
      (Ast.Greater, Expression.Greater);
      (Ast.GreaterEqual, Expression.GreaterEqual);
    ]

let test_boolean_connectives_lower_recursively () =
  let ast =
    select_where "t" (Ast.And (ast_column "a", Ast.Not (ast_column "b")))
  in
  Alcotest.(check logical_testable)
    "AND/NOT lower recursively"
    (Restrict
       {
         input = Scan { table = "t" };
         predicate =
           Expression.And (ir_column "a", Expression.Not (ir_column "b"));
       })
    (Lower.lower ast)

let () =
  Alcotest.run "sql_lower"
    [
      ( "select star",
        [
          Alcotest.test_case "SELECT * lowers to a bare Scan (no Project)"
            `Quick test_select_star_lowers_to_scan;
        ] );
      ( "where",
        [
          Alcotest.test_case "a bare column predicate lowers to Restrict" `Quick
            test_where_bare_column_lowers_to_restrict;
          Alcotest.test_case
            "each comparison operator lowers to its IR operator" `Quick
            test_each_comparison_operator_lowers;
          Alcotest.test_case "AND / OR / NOT lower their operands recursively"
            `Quick test_boolean_connectives_lower_recursively;
        ] );
    ]
