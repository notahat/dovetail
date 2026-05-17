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
    capturing all formatter output as a string. [show_physical] defaults to
    [false], matching the binary's default. *)
let run_with_input ?(show_physical = false) lines =
  let captured = Buffer.create 512 in
  let formatter = Format.formatter_of_buffer captured in
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Repl.run ~show_physical environment
    ~read_line:(read_line_from_list lines)
    ~output:formatter;
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
  let output = run_with_input [ "nonexistent_table"; "users" ] in
  check_contains "after eval error" output "error:";
  check_contains "after eval error" output "Alice"

let test_blank_lines_are_skipped_without_error () =
  let output = run_with_input [ ""; "   "; "users" ] in
  Alcotest.(check bool)
    "no parse error from blank input" false
    (contains_substring output "parse error");
  check_contains "blank lines tolerated" output "Alice"

let test_show_physical_defaults_off_omits_plan () =
  let output = run_with_input [ "users" ] in
  Alcotest.(check bool)
    "no FullScan in default output" false
    (contains_substring output "FullScan")

let test_show_physical_prints_plan_before_results () =
  (* [restrict active] stays as Filter(FullScan) -- a predicate that
     doesn't fold to IndexLookup, so the printed plan has two lines and
     this test can check both the header and the indented input. *)
  let output =
    run_with_input ~show_physical:true [ "users | restrict active" ]
  in
  check_contains "plan header line" output "Filter(active)";
  check_contains "plan input line" output "FullScan(users)";
  (* The plan prints before the result table; assert ordering by checking
     that "FullScan" appears before the first row's name in the captured
     output. *)
  let plan_position =
    String.index output 'F'
    (* opening "FullScan" *)
  in
  let row_position =
    let rec search position =
      if position >= String.length output - 5 then String.length output
      else if String.sub output position 5 = "Alice" then position
      else search (position + 1)
    in
    search 0
  in
  Alcotest.(check bool)
    "plan precedes the result rows" true
    (plan_position < row_position)

let test_relation_literal_alone_prints_one_row () =
  let output = run_with_input [ "{id: 7, name: \"Pretzel\", amount: 9}" ] in
  (* Bare column headers, no qualifier prefix. *)
  check_contains "literal column headers" output "│ id │ name";
  check_contains "literal column headers" output "amount";
  (* The literal's own values appear in the row. *)
  check_contains "literal row values" output "Pretzel";
  check_contains "literal row values" output " 7 ";
  check_contains "literal row values" output " 9 "

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
          Alcotest.test_case "show-physical defaults off and omits the plan"
            `Quick test_show_physical_defaults_off_omits_plan;
          Alcotest.test_case
            "show-physical prints the plan before the result rows" `Quick
            test_show_physical_prints_plan_before_results;
          Alcotest.test_case
            "a bare relation literal prints as a one-row relation" `Quick
            test_relation_literal_alone_prints_one_row;
        ] );
    ]
