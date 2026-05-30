(** Tests for [Parser]. *)

open Dovetail_surface_sql
module Scalar = Dovetail_core.Scalar

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

(* Compare the parser's output against an expected [Ast.t]. *)
let parses input expected_ast =
  match Parser.parse input with
  | Ok actual_ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses" input)
        expected_ast actual_ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

let select_all_from table =
  Ast.Select { select_list = Ast.All; from = table; where = None }

(* A [SELECT * FROM <table> WHERE <predicate>] expectation. *)
let select_where table predicate =
  Ast.Select { select_list = Ast.All; from = table; where = Some predicate }

(* Build a bare (unqualified) column reference in expression position. *)
let column name : Ast.expression = Ast.Column { qualifier = None; name }

(* A bare column reference for a select list. *)
let column_ref name : Ast.column_reference = { qualifier = None; name }

(* A [SELECT <columns> FROM <table>] expectation with a column-list select. *)
let select_columns table names =
  Ast.Select
    {
      select_list = Ast.Columns (List.map column_ref names);
      from = table;
      where = None;
    }

(* Build an int64-literal expression. *)
let int64 number : Ast.expression = Ast.Literal (Scalar.Int64 number)

let test_parses_select_star_from_table () =
  parses "SELECT * FROM users" (select_all_from "users")

let test_keywords_are_case_insensitive () =
  parses "select * from users" (select_all_from "users")

let test_keywords_tolerate_mixed_case () =
  parses "SeLeCt * FrOm users" (select_all_from "users")

let test_identifier_is_case_sensitive () =
  parses "SELECT * FROM Users" (select_all_from "Users")

let test_tolerates_extra_whitespace_between_tokens () =
  parses "SELECT   *   FROM   users" (select_all_from "users")

let test_tolerates_surrounding_whitespace () =
  parses "\n\t  SELECT * FROM users  \n" (select_all_from "users")

let test_accepts_optional_trailing_semicolon () =
  parses "SELECT * FROM users;" (select_all_from "users")

let test_tolerates_whitespace_before_semicolon () =
  parses "SELECT * FROM users ;" (select_all_from "users")

let test_rejects_empty_input () = rejects ""
let test_rejects_whitespace_only_input () = rejects "   "
let test_rejects_missing_from () = rejects "SELECT * users"
let test_rejects_missing_star () = rejects "SELECT FROM users"
let test_rejects_missing_table () = rejects "SELECT * FROM"

let test_rejects_trailing_junk_after_table () =
  rejects "SELECT * FROM users orders"

let test_rejects_trailing_junk_after_semicolon () =
  rejects "SELECT * FROM users; SELECT * FROM orders"

let test_rejects_double_semicolon () = rejects "SELECT * FROM users;;"

let test_parses_simple_comparison () =
  parses "SELECT * FROM users WHERE id = 1"
    (select_where "users"
       (Ast.Compare { left = column "id"; op = Ast.Equal; right = int64 1L }))

let test_parses_single_quoted_string_literal () =
  parses "SELECT * FROM users WHERE name = 'Alice'"
    (select_where "users"
       (Ast.Compare
          {
            left = column "name";
            op = Ast.Equal;
            right = Ast.Literal (Scalar.String "Alice");
          }))

let test_parses_each_comparison_operator () =
  List.iter
    (fun (operator_text, expected_op) ->
      parses
        (Printf.sprintf "SELECT * FROM t WHERE a %s 1" operator_text)
        (select_where "t"
           (Ast.Compare
              { left = column "a"; op = expected_op; right = int64 1L })))
    [
      ("=", Ast.Equal);
      ("<>", Ast.NotEqual);
      ("!=", Ast.NotEqual);
      ("<", Ast.Less);
      ("<=", Ast.LessEqual);
      (">", Ast.Greater);
      (">=", Ast.GreaterEqual);
    ]

let test_where_keyword_is_case_insensitive () =
  parses "SELECT * FROM users where id = 1"
    (select_where "users"
       (Ast.Compare { left = column "id"; op = Ast.Equal; right = int64 1L }))

let test_parses_bare_boolean_column_as_predicate () =
  parses "SELECT * FROM users WHERE active"
    (select_where "users" (column "active"))

let test_parses_true_and_false_literals () =
  parses "SELECT * FROM users WHERE TRUE"
    (select_where "users" (Ast.Literal (Scalar.Bool true)));
  parses "SELECT * FROM users WHERE false"
    (select_where "users" (Ast.Literal (Scalar.Bool false)))

let test_parses_and_chain () =
  parses "SELECT * FROM t WHERE a AND b"
    (select_where "t" (Ast.And (column "a", column "b")))

let test_parses_or_chain () =
  parses "SELECT * FROM t WHERE a OR b"
    (select_where "t" (Ast.Or (column "a", column "b")))

let test_and_binds_tighter_than_or () =
  parses "SELECT * FROM t WHERE a OR b AND c"
    (select_where "t" (Ast.Or (column "a", Ast.And (column "b", column "c"))))

let test_and_is_left_associative () =
  parses "SELECT * FROM t WHERE a AND b AND c"
    (select_where "t" (Ast.And (Ast.And (column "a", column "b"), column "c")))

let test_parses_not_prefix () =
  parses "SELECT * FROM t WHERE NOT active"
    (select_where "t" (Ast.Not (column "active")))

let test_not_binds_looser_than_comparison () =
  parses "SELECT * FROM t WHERE NOT a = 1"
    (select_where "t"
       (Ast.Not
          (Ast.Compare { left = column "a"; op = Ast.Equal; right = int64 1L })))

let test_parens_override_precedence () =
  parses "SELECT * FROM t WHERE (a OR b) AND c"
    (select_where "t" (Ast.And (Ast.Or (column "a", column "b"), column "c")))

let test_keywords_in_predicate_tolerate_mixed_case () =
  parses "SELECT * FROM t WHERE NoT a aNd b oR c"
    (select_where "t"
       (Ast.Or (Ast.And (Ast.Not (column "a"), column "b"), column "c")))

let test_rejects_qualified_column_in_predicate () =
  rejects "SELECT * FROM users WHERE users.id = 1"

let test_rejects_where_with_no_predicate () =
  rejects "SELECT * FROM users WHERE"

let test_rejects_double_quoted_string_literal () =
  rejects "SELECT * FROM users WHERE name = \"Alice\""

let test_parses_single_column_select () =
  parses "SELECT id FROM users" (select_columns "users" [ "id" ])

let test_parses_multiple_column_select_preserving_order () =
  parses "SELECT id, name, email FROM users"
    (select_columns "users" [ "id"; "name"; "email" ])

let test_tolerates_whitespace_around_select_list_commas () =
  parses "SELECT id,name , email FROM users"
    (select_columns "users" [ "id"; "name"; "email" ])

let test_star_and_column_list_parse_distinctly () =
  parses "SELECT * FROM users" (select_all_from "users");
  parses "SELECT id FROM users" (select_columns "users" [ "id" ])

let test_parses_column_list_with_where () =
  parses "SELECT id, name FROM users WHERE active"
    (Ast.Select
       {
         select_list = Ast.Columns [ column_ref "id"; column_ref "name" ];
         from = "users";
         where = Some (column "active");
       })

let test_rejects_trailing_comma_in_select_list () =
  rejects "SELECT id, FROM users"

let test_rejects_qualified_column_in_select_list () =
  rejects "SELECT users.id FROM users"

let test_rejects_leading_comma_in_select_list () =
  rejects "SELECT , id FROM users"

let () =
  Alcotest.run "sql_parser"
    [
      ( "select star",
        [
          Alcotest.test_case "parses SELECT * FROM <table>" `Quick
            test_parses_select_star_from_table;
          Alcotest.test_case "keywords are case-insensitive" `Quick
            test_keywords_are_case_insensitive;
          Alcotest.test_case "keywords tolerate mixed case" `Quick
            test_keywords_tolerate_mixed_case;
          Alcotest.test_case "identifiers are case-sensitive" `Quick
            test_identifier_is_case_sensitive;
          Alcotest.test_case "tolerates extra whitespace between tokens" `Quick
            test_tolerates_extra_whitespace_between_tokens;
          Alcotest.test_case "tolerates surrounding whitespace" `Quick
            test_tolerates_surrounding_whitespace;
          Alcotest.test_case "accepts an optional trailing semicolon" `Quick
            test_accepts_optional_trailing_semicolon;
          Alcotest.test_case "tolerates whitespace before the semicolon" `Quick
            test_tolerates_whitespace_before_semicolon;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_rejects_whitespace_only_input;
          Alcotest.test_case "rejects a missing FROM" `Quick
            test_rejects_missing_from;
          Alcotest.test_case "rejects a missing *" `Quick
            test_rejects_missing_star;
          Alcotest.test_case "rejects a missing table name" `Quick
            test_rejects_missing_table;
          Alcotest.test_case "rejects trailing junk after the table" `Quick
            test_rejects_trailing_junk_after_table;
          Alcotest.test_case "rejects trailing junk after the semicolon" `Quick
            test_rejects_trailing_junk_after_semicolon;
          Alcotest.test_case "rejects a double semicolon" `Quick
            test_rejects_double_semicolon;
        ] );
      ( "where",
        [
          Alcotest.test_case "parses a simple comparison predicate" `Quick
            test_parses_simple_comparison;
          Alcotest.test_case "parses a single-quoted string literal" `Quick
            test_parses_single_quoted_string_literal;
          Alcotest.test_case "parses each comparison operator" `Quick
            test_parses_each_comparison_operator;
          Alcotest.test_case "the WHERE keyword is case-insensitive" `Quick
            test_where_keyword_is_case_insensitive;
          Alcotest.test_case "parses a bare boolean column as a predicate"
            `Quick test_parses_bare_boolean_column_as_predicate;
          Alcotest.test_case "parses TRUE and FALSE literals" `Quick
            test_parses_true_and_false_literals;
          Alcotest.test_case "parses an AND chain" `Quick test_parses_and_chain;
          Alcotest.test_case "parses an OR chain" `Quick test_parses_or_chain;
          Alcotest.test_case "AND binds tighter than OR" `Quick
            test_and_binds_tighter_than_or;
          Alcotest.test_case "AND is left-associative" `Quick
            test_and_is_left_associative;
          Alcotest.test_case "parses a NOT prefix" `Quick test_parses_not_prefix;
          Alcotest.test_case "NOT binds looser than comparison" `Quick
            test_not_binds_looser_than_comparison;
          Alcotest.test_case "parentheses override precedence" `Quick
            test_parens_override_precedence;
          Alcotest.test_case "predicate keywords tolerate mixed case" `Quick
            test_keywords_in_predicate_tolerate_mixed_case;
          Alcotest.test_case "rejects a qualified column in the predicate"
            `Quick test_rejects_qualified_column_in_predicate;
          Alcotest.test_case "rejects WHERE with no predicate" `Quick
            test_rejects_where_with_no_predicate;
          Alcotest.test_case "rejects a double-quoted string literal" `Quick
            test_rejects_double_quoted_string_literal;
        ] );
      ( "select list",
        [
          Alcotest.test_case "parses a single-column select" `Quick
            test_parses_single_column_select;
          Alcotest.test_case "parses a multi-column select preserving order"
            `Quick test_parses_multiple_column_select_preserving_order;
          Alcotest.test_case "tolerates whitespace around select-list commas"
            `Quick test_tolerates_whitespace_around_select_list_commas;
          Alcotest.test_case "* and a column list parse to distinct ASTs" `Quick
            test_star_and_column_list_parse_distinctly;
          Alcotest.test_case "parses a column list with a WHERE clause" `Quick
            test_parses_column_list_with_where;
          Alcotest.test_case "rejects a trailing comma in the select list"
            `Quick test_rejects_trailing_comma_in_select_list;
          Alcotest.test_case "rejects a qualified column in the select list"
            `Quick test_rejects_qualified_column_in_select_list;
          Alcotest.test_case "rejects a leading comma in the select list" `Quick
            test_rejects_leading_comma_in_select_list;
        ] );
    ]
