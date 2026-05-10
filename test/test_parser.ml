(** Tests for [Parser]. *)

open Dovetail
open Test_helpers

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

let parses input expected_ast =
  match Parser.parse input with
  | Ok ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses" input)
        expected_ast ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

let test_parses_bare_identifier () = parses "users" (Ast.Relation_name "users")

let test_tolerates_leading_whitespace () =
  parses "   users" (Ast.Relation_name "users")

let test_tolerates_trailing_whitespace () =
  parses "users   " (Ast.Relation_name "users")

let test_tolerates_surrounding_whitespace_with_tabs_and_newlines () =
  parses "\n\tusers\n" (Ast.Relation_name "users")

let test_accepts_digits_and_underscores_after_first_character () =
  parses "users_2" (Ast.Relation_name "users_2")

let test_rejects_empty_input () = rejects ""
let test_rejects_whitespace_only_input () = rejects "   "
let test_rejects_identifier_starting_with_digit () = rejects "1users"
let test_rejects_identifier_starting_with_underscore () = rejects "_users"

let test_rejects_two_identifiers () =
  (* Multiple tokens are out of scope for slice 1's grammar; the parser must
     refuse them now so we don't accidentally start accepting them later. *)
  rejects "users orders"

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows from parsed query" expected_users_rows rows)

let () =
  Alcotest.run "parser"
    [
      ( "identifier",
        [
          Alcotest.test_case "parses a bare identifier" `Quick
            test_parses_bare_identifier;
          Alcotest.test_case "tolerates leading whitespace" `Quick
            test_tolerates_leading_whitespace;
          Alcotest.test_case "tolerates trailing whitespace" `Quick
            test_tolerates_trailing_whitespace;
          Alcotest.test_case
            "tolerates surrounding whitespace with tabs and newlines" `Quick
            test_tolerates_surrounding_whitespace_with_tabs_and_newlines;
          Alcotest.test_case "accepts digits and underscores after the first"
            `Quick test_accepts_digits_and_underscores_after_first_character;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_rejects_whitespace_only_input;
          Alcotest.test_case "rejects identifier starting with a digit" `Quick
            test_rejects_identifier_starting_with_digit;
          Alcotest.test_case "rejects identifier starting with an underscore"
            `Quick test_rejects_identifier_starting_with_underscore;
          Alcotest.test_case "rejects two identifiers" `Quick
            test_rejects_two_identifiers;
        ] );
      ( "pipeline",
        [
          Alcotest.test_case
            "parsed query, lowered/translated/evaluated, yields fixture rows"
            `Quick test_pipeline_yields_fixture_rows;
        ] );
    ]
