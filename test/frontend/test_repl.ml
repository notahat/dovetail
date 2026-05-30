(** Tests for [Repl]. *)

open Dovetail_frontend
open Test_helpers

(** Run the REPL against a populated environment with [lines] as input,
    capturing all formatter output as a string. [show_logical] and
    [show_physical] default to [false], matching the binary's defaults. *)
let run_with_input ?(show_logical = false) ?(show_physical = false)
    ?(surface = `Ra) lines =
  with_fixture_environment @@ fun environment ->
  with_captured_formatter @@ fun formatter ->
  Repl.run ~show_logical ~show_physical ~surface environment
    ~read_line:(read_line_from_list lines)
    ~output:formatter

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

let test_show_logical_defaults_off_omits_plan () =
  let output = run_with_input [ "users" ] in
  Alcotest.(check bool)
    "no Scan( in default output" false
    (contains_substring output "Scan(")

let test_show_logical_prints_plan_before_results () =
  let output =
    run_with_input ~show_logical:true [ "users | restrict active" ]
  in
  check_contains "logical header line" output "Restrict(active)";
  check_contains "logical input line" output "Scan(users)";
  let plan_position =
    String.index output 'R'
    (* opening "Restrict" *)
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
    "logical plan precedes the result rows" true
    (plan_position < row_position)

let test_both_show_flags_print_logical_then_physical () =
  (* [restrict active] keeps Restrict/Filter separate (no IndexLookup fold),
     so the logical and physical plans render distinguishable header lines.
     Asserting Restrict appears before Filter pins down the ordering: the
     REPL prints logical (pipeline-direction first) before physical. *)
  let output =
    run_with_input ~show_logical:true ~show_physical:true
      [ "users | restrict active" ]
  in
  check_contains "logical header present" output "Restrict(active)";
  check_contains "physical header present" output "Filter(active)";
  let logical_position =
    let rec search position =
      if position >= String.length output - 8 then String.length output
      else if String.sub output position 8 = "Restrict" then position
      else search (position + 1)
    in
    search 0
  in
  let physical_position =
    let rec search position =
      if position >= String.length output - 6 then String.length output
      else if String.sub output position 6 = "Filter" then position
      else search (position + 1)
    in
    search 0
  in
  Alcotest.(check bool)
    "logical plan precedes physical plan" true
    (logical_position < physical_position)

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

(* End-to-end: a user-typed insert pipeline runs through parse / lower /
   translate / eval, commits the row inside a write transaction, and prints
   a one-row [(insert_count : int64)] relation reporting the affected-row
   count. The follow-up restrict query confirms the row landed in storage
   and is readable. *)
let test_insert_into_orders_writes_row_and_reports_count () =
  let output =
    run_with_input
      [
        "relation (id: int64, user_id: int64, description: string, amount: \
         int64) { (id = 9, user_id = 1, description = \"Pretzel\", amount = 9) \
         } | insert into orders";
        "orders | restrict id = 9";
      ]
  in
  check_contains "insert result column header" output "insert_count";
  check_contains "insert result count cell" output "insert_count = 1";
  check_contains "inserted row's description" output "Pretzel";
  check_contains "inserted row's id field" output "orders.id = 9"

(* A join produces qualified field names, and piping that directly into
   [insert into] is the prototypical mistake the sink's qualifier check
   catches. The error names every offending field and points the user
   at [unqualify] as the explicit strip. *)
let test_insert_from_join_is_rejected_with_unqualify_hint () =
  let output =
    run_with_input
      [
        "users | join orders on users.id = orders.user_id | insert into orders";
      ]
  in
  check_contains "rejects qualified source" output "Insert: into \"orders\":";
  check_contains "names an offending qualified field" output "\"users.id\"";
  check_contains "points at unqualify" output "unqualify"

(* The full join | project | unqualify | insert into chain: confirms the
   downstream sink accepts the upstream pipeline's rows once the qualifiers
   have been explicitly stripped. The test creates an empty target table
   inside the same REPL session, runs the chain, and asserts the printed
   affected-row count matches the join's six matched pairs. *)
let test_unqualify_unblocks_join_to_insert_chain () =
  let output =
    run_with_input
      [
        "(id: int64, user_id: int64, primary key (id)) | create table joined";
        "users | join orders on users.id = orders.user_id | project orders.id, \
         orders.user_id | unqualify | insert into joined";
      ]
  in
  check_contains "insert succeeds and reports six affected rows" output
    "insert_count = 6"

(* End-to-end: the pipe-source leaf [drop table <name>] parses,
   classifies as a write, removes the catalog entry and storage subDB
   inside a write transaction, and yields a one-row
   [(dropped = "<name>")] relation. The follow-up [catalog | tables]
   confirms the table is gone while its sibling remains. *)
let test_drop_table_removes_table_and_reports_status () =
  let output = run_with_input [ "drop table users"; "catalog | tables" ] in
  check_contains "drop result row" output "dropped = \"users\"";
  check_contains "orders still listed after drop" output "name = \"orders\"";
  Alcotest.(check bool)
    "users not listed after drop" false
    (* The post-drop [catalog | tables] output is the only place a bare
       [name = "users"] row would appear after the drop, so its absence
       here is the assertion. *)
    (contains_substring output "name = \"users\"")

(* The "no such table" error path: dropping an unseeded table raises in
   [Eval], the REPL catches it via its generic error guard, prints the
   failure with the [Drop table: ...: no such table] prefix, and
   continues so the follow-up query still executes. *)
let test_drop_nonexistent_table_reports_error_and_continues () =
  let output =
    run_with_input [ "drop table nonexistent"; "catalog | tables" ]
  in
  check_contains "no-such-table error" output
    "Drop table: \"nonexistent\": no such table";
  check_contains "loop continues after drop error" output "name = \"users\"";
  check_contains "loop continues after drop error" output "name = \"orders\""

let test_relation_literal_alone_prints_one_row () =
  let output =
    run_with_input
      [
        "relation (id: int64, name: string, amount: int64) { (id = 7, name = \
         \"Pretzel\", amount = 9) }";
      ]
  in
  (* Bare field names, no qualifier prefix, in the literal's row kind. *)
  check_contains "literal row kind" output
    "relation (id: int64, name: string, amount: int64)";
  (* The literal's own values appear in the row, qualifier-free. *)
  check_contains "literal row id" output "id = 7";
  check_contains "literal row name" output "name = \"Pretzel\"";
  check_contains "literal row amount" output "amount = 9"

(* End-to-end proof that the REPL's [Relation_value] dispatch produces the
   canonical relation-literal form and that the embedded row kind and
   per-row literals carry the join's qualifiers. *)
let test_post_join_renders_canonical_qualified_literal () =
  let output =
    run_with_input [ "users | join orders on users.id = orders.user_id" ]
  in
  check_contains "canonical literal preamble with qualified row kind" output
    "relation (users.id: int64, users.name: string,";
  check_contains "qualified field on the join's left side" output "users.id = ";
  check_contains "qualified field on the join's right side" output
    "orders.user_id = "

(* The SQL surface runs end-to-end in-process: a [~surface:`Sql] session
   parses [SELECT * FROM users] with the SQL parser, lowers it to the same
   logical Scan the RA surface produces, and prints the fixture rows. This
   is the first place SQL runs through the full pipeline. *)
let test_sql_select_star_prints_all_five_rows () =
  let output = run_with_input ~surface:`Sql [ "SELECT * FROM users" ] in
  List.iter
    (fun name -> check_contains "sql select" output name)
    [ "Alice"; "Bob"; "Carol"; "Dave"; "Eve" ];
  check_contains "sql select" output "alice@example.com"

(* The SQL session prompts with [sql> ] so transcripts show which surface
   is live; the RA session keeps [> ]. *)
let test_sql_session_uses_the_sql_prompt () =
  let output = run_with_input ~surface:`Sql [] in
  Alcotest.(check string) "sql prompt" "sql> " output

let test_ra_session_keeps_the_default_prompt () =
  let output = run_with_input ~surface:`Ra [] in
  Alcotest.(check string) "ra prompt" "> " output

(* A SQL parse failure lands in the same [parse error:] channel the RA
   surface uses, and the loop continues so the next line still runs. *)
let test_sql_parse_error_continues_loop () =
  let output =
    run_with_input ~surface:`Sql [ "SELECT FROM users"; "SELECT * FROM users" ]
  in
  check_contains "sql parse error" output "parse error";
  check_contains "loop continues after sql parse error" output "Alice"

(* A SQL query against a missing table reaches eval and reports the same
   [error:] the RA surface would, then the loop continues. *)
let test_sql_eval_error_continues_loop () =
  let output =
    run_with_input ~surface:`Sql
      [ "SELECT * FROM nonexistent"; "SELECT * FROM users" ]
  in
  check_contains "sql eval error" output "error:";
  check_contains "loop continues after sql eval error" output "Alice"

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
          Alcotest.test_case "show-logical defaults off and omits the plan"
            `Quick test_show_logical_defaults_off_omits_plan;
          Alcotest.test_case
            "show-logical prints the plan before the result rows" `Quick
            test_show_logical_prints_plan_before_results;
          Alcotest.test_case "both show flags print logical before physical"
            `Quick test_both_show_flags_print_logical_then_physical;
          Alcotest.test_case
            "a bare relation literal prints as a one-row relation" `Quick
            test_relation_literal_alone_prints_one_row;
          Alcotest.test_case
            "insert into orders writes the row and prints the insert_count \
             relation"
            `Quick test_insert_into_orders_writes_row_and_reports_count;
          Alcotest.test_case
            "insert into rejects a join's qualified output and suggests \
             unqualify"
            `Quick test_insert_from_join_is_rejected_with_unqualify_hint;
          Alcotest.test_case
            "join | project | unqualify | insert into chain writes the rows"
            `Quick test_unqualify_unblocks_join_to_insert_chain;
          Alcotest.test_case
            "[drop table <name>] removes the table and yields a result row"
            `Quick test_drop_table_removes_table_and_reports_status;
          Alcotest.test_case
            "[drop table <missing>] reports the error and continues" `Quick
            test_drop_nonexistent_table_reports_error_and_continues;
          Alcotest.test_case
            "a post-join relation renders as the canonical qualified literal"
            `Quick test_post_join_renders_canonical_qualified_literal;
          Alcotest.test_case "a SQL SELECT * session prints all five rows"
            `Quick test_sql_select_star_prints_all_five_rows;
          Alcotest.test_case "the SQL session uses the sql> prompt" `Quick
            test_sql_session_uses_the_sql_prompt;
          Alcotest.test_case "the RA session keeps the default prompt" `Quick
            test_ra_session_keeps_the_default_prompt;
          Alcotest.test_case "loop continues after a SQL parse error" `Quick
            test_sql_parse_error_continues_loop;
          Alcotest.test_case "loop continues after a SQL eval error" `Quick
            test_sql_eval_error_continues_loop;
        ] );
    ]
