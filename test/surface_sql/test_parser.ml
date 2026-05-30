(** Tests for [Parser]. *)

open Dovetail_surface_sql

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

let select_all_from table = Ast.Select { select_list = Ast.All; from = table }

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
    ]
