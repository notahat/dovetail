(** Tests for [Repl]. *)

open Dovetail
open Test_helpers

(** Build a [read_line] callback that returns each string in [lines] in order,
    then [None] forever. *)
let read_line_from_list lines =
  let remaining = ref lines in
  fun () ->
    match !remaining with
    | [] -> None
    | head :: rest ->
        remaining := rest;
        Some head

(** Run the REPL against a populated environment with [lines] as input,
    capturing all formatter output as a string. *)
let run_with_input lines =
  let captured = Buffer.create 512 in
  let formatter = Format.formatter_of_buffer captured in
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Repl.run environment ~read_line:(read_line_from_list lines) ~output:formatter;
  Format.pp_print_flush formatter ();
  Buffer.contents captured

let check_contains label output expected =
  if not (contains_substring output expected) then
    Alcotest.failf "%s: expected output to contain %S\n--- output ---\n%s" label
      expected output

let test_eof_alone_exits_after_one_prompt () =
  let output = run_with_input [] in
  Alcotest.(check string) "single prompt" "> " output

let test_users_query_prints_all_five_rows () =
  let output = run_with_input [ "users" ] in
  List.iter
    (fun name -> check_contains "users query" output name)
    [ "Alice"; "Bob"; "Carol"; "Dave"; "Eve" ];
  check_contains "users query" output "alice@example.com"

let test_parse_error_continues_loop () =
  let output = run_with_input [ "1users"; "users" ] in
  check_contains "after parse error" output "parse error";
  (* Loop must keep running after the bad line, so the second query gets
     a chance to print its rows. *)
  check_contains "after parse error" output "Alice"

let test_eval_error_continues_loop () =
  let output = run_with_input [ "orders"; "users" ] in
  check_contains "after eval error" output "error:";
  check_contains "after eval error" output "Alice"

let test_blank_lines_are_skipped_without_error () =
  let output = run_with_input [ ""; "   "; "users" ] in
  Alcotest.(check bool)
    "no parse error from blank input" false
    (contains_substring output "parse error");
  check_contains "blank lines tolerated" output "Alice"

let () =
  Alcotest.run "repl"
    [
      ( "loop",
        [
          Alcotest.test_case "EOF alone exits after one prompt" `Quick
            test_eof_alone_exits_after_one_prompt;
          Alcotest.test_case "the users query prints all five rows" `Quick
            test_users_query_prints_all_five_rows;
          Alcotest.test_case "loop continues after a parse error" `Quick
            test_parse_error_continues_loop;
          Alcotest.test_case "loop continues after an eval error" `Quick
            test_eval_error_continues_loop;
          Alcotest.test_case "blank and whitespace-only lines are skipped"
            `Quick test_blank_lines_are_skipped_without_error;
        ] );
    ]
