(** Tests for [Repl]. *)

open Dovetail_frontend
open Test_helpers

(** Run the REPL against a populated environment with [lines] as input,
    capturing all formatter output as a string. [show_logical] and
    [show_physical] default to [false], matching the binary's defaults. *)
let run_with_input ?(show_logical = false) ?(show_physical = false) lines =
  with_fixture_environment @@ fun environment ->
  with_captured_formatter @@ fun formatter ->
  Repl.run ~show_logical ~show_physical environment
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
        "{id: 9, user_id: 1, description: \"Pretzel\", amount: 9} | insert \
         into orders";
        "orders | restrict id = 9";
      ]
  in
  check_contains "insert result column header" output "insert_count";
  check_contains "insert result count cell" output " 1 ";
  check_contains "inserted row's description" output "Pretzel";
  check_contains "inserted row's id column" output " 9 "

(* [:list tables] runs through Parser → REPL DDL
   dispatch → Ddl_executor.execute_read → Catalog.list_table_names and
   prints each table name on its own line. The fixture seeds [users] and
   [orders]; cursor (byte-sorted) order puts [orders] first. *)
let test_list_tables_prints_fixture_tables_in_byte_sorted_order () =
  let output = run_with_input [ ":list tables" ] in
  check_contains ":list tables output" output "orders";
  check_contains ":list tables output" output "users";
  let orders_position =
    let rec search position =
      if position >= String.length output - 6 then String.length output
      else if String.sub output position 6 = "orders" then position
      else search (position + 1)
    in
    search 0
  in
  let users_position =
    let rec search position =
      if position >= String.length output - 5 then String.length output
      else if String.sub output position 5 = "users" then position
      else search (position + 1)
    in
    search 0
  in
  Alcotest.(check bool)
    "orders precedes users (byte-sorted)" true
    (orders_position < users_position)

(* End-to-end: [:drop table <name>] parses, classifies
   as a write, removes the catalog entry and storage subDB inside a
   write transaction, and prints the [dropped table "<name>"] status.
   The follow-up [:list tables] confirms the table is gone while its
   sibling remains. *)
let test_drop_table_removes_table_and_reports_status () =
  let output = run_with_input [ ":drop table users"; ":list tables" ] in
  check_contains "drop status line" output "dropped table \"users\"";
  check_contains "orders still listed after drop" output "orders";
  Alcotest.(check bool)
    "users not listed after drop" false
    (* Match a whole-token "users" on its own line so substrings like
       [alice@example.com] in earlier output can't satisfy the check.
       The post-drop list output is the only place a bare [users] would
       appear after the drop, so its absence here is the assertion. *)
    (contains_substring output "\nusers\n")

(* The "no such table" error path: dropping an unseeded table raises in
   [Ddl_executor.execute_write], the REPL catches it via its generic error
   guard, prints the failure with the [DDL: drop table ...: no such table]
   prefix, and continues so the follow-up query still executes. *)
let test_drop_nonexistent_table_reports_error_and_continues () =
  let output = run_with_input [ ":drop table nonexistent"; ":list tables" ] in
  check_contains "no-such-table error" output
    "DDL: drop table \"nonexistent\": no such table";
  check_contains "loop continues after drop error" output "users";
  check_contains "loop continues after drop error" output "orders"

(* [Statement.validate] runs between parse and the transaction. All five
   validate rules are reachable from the REPL -- the empty-list cases
   surface as validate errors so the user sees the friendly
   [DDL: create table ...] message rather than angstrom's raw [satisfy:
   ')'] surface. Each REPL-level test feeds an offending [:create table]
   line, asserts the rendered [error: DDL: ...] string verbatim, and
   then runs [:list tables] to confirm the offending table never reached
   the catalog. *)

let test_create_table_empty_column_list_reports_validate_error () =
  let output =
    run_with_input
      [ ":create table widgets () primary key (id)"; ":list tables" ]
  in
  check_contains "empty-column-list validate error" output
    "error: DDL: create table \"widgets\": column list is empty";
  Alcotest.(check bool)
    "widgets not listed after validate error" false
    (contains_substring output "\nwidgets\n")

let test_create_table_empty_primary_key_list_reports_validate_error () =
  let output =
    run_with_input
      [ ":create table widgets (id: Int64) primary key ()"; ":list tables" ]
  in
  check_contains "empty-primary-key-list validate error" output
    "error: DDL: create table \"widgets\": primary key is empty";
  Alcotest.(check bool)
    "widgets not listed after validate error" false
    (contains_substring output "\nwidgets\n")

let test_create_table_duplicate_column_reports_validate_error () =
  let output =
    run_with_input
      [
        ":create table widgets (id: Int64, id: String) primary key (id)";
        ":list tables";
      ]
  in
  check_contains "duplicate-column validate error" output
    "error: DDL: create table \"widgets\": column \"id\" appears twice";
  Alcotest.(check bool)
    "widgets not listed after validate error" false
    (contains_substring output "\nwidgets\n")

let test_create_table_primary_key_unknown_column_reports_validate_error () =
  let output =
    run_with_input
      [
        ":create table widgets (id: Int64, name: String) primary key (xyz)";
        ":list tables";
      ]
  in
  check_contains "unknown-pk-column validate error" output
    "error: DDL: create table \"widgets\": primary key column \"xyz\" not in \
     column list";
  Alcotest.(check bool)
    "widgets not listed after validate error" false
    (contains_substring output "\nwidgets\n")

let test_create_table_duplicate_primary_key_column_reports_validate_error () =
  let output =
    run_with_input
      [
        ":create table widgets (id: Int64) primary key (id, id)"; ":list tables";
      ]
  in
  check_contains "duplicate-pk-column validate error" output
    "error: DDL: create table \"widgets\": primary key column \"id\" appears \
     twice";
  Alcotest.(check bool)
    "widgets not listed after validate error" false
    (contains_substring output "\nwidgets\n")

(* The [Created] renderer plus the end-to-end
   exercise of [:create table]. The sequence creates [widgets], lists
   the catalog (the new table appears alongside the fixture tables),
   inspects [widgets]'s type via [widgets | type], drops it, and lists
   again (it is gone). The fixture tables (orders, users) remain
   present throughout so the test also sees that the create did not
   disturb the sibling tables. *)
let test_create_table_end_to_end_sequence () =
  let output =
    run_with_input
      [
        ":create table widgets (id: Int64, name: String) primary key (id)";
        ":list tables";
        "widgets | type";
        ":drop table widgets";
        ":list tables";
      ]
  in
  check_contains "create status line" output "created table \"widgets\"";
  check_contains "widgets | type renders the relation type" output
    "(id: int64, name: string, primary key (id))";
  check_contains "drop status line" output "dropped table \"widgets\"";
  (* The substring [\nwidgets\n] is the listing-line shape: a table name
     on its own line in a [:list tables] block. It appears exactly once
     -- in the first listing, between the create and the drop. The
     second listing comes after the drop and must not contain it. *)
  Alcotest.(check int)
    "widgets appears in the first listing but not the second" 1
    (count_substring output "\nwidgets\n");
  check_contains "fixture tables survive create+drop" output "orders";
  check_contains "fixture tables survive create+drop" output "users"

(* The catalog-aware "table already exists" check lives in the executor
   and raises with a [DDL: create table ...] prefix; the REPL's generic
   error guard turns the raise into an [error: ...] line and the loop
   continues. Creating [users] (a fixture table) is the simplest way
   to exercise this without pre-populating any extra state. *)
let test_create_table_already_exists_reports_error_and_continues () =
  let output =
    run_with_input
      [ ":create table users (id: Int64) primary key (id)"; ":list tables" ]
  in
  check_contains "already-exists error" output
    "error: DDL: create table \"users\": table already exists";
  check_contains "loop continues after create error" output "orders";
  check_contains "loop continues after create error" output "users"

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
            ":list tables prints fixture tables in byte-sorted order" `Quick
            test_list_tables_prints_fixture_tables_in_byte_sorted_order;
          Alcotest.test_case
            ":drop table removes the table and prints the status line" `Quick
            test_drop_table_removes_table_and_reports_status;
          Alcotest.test_case
            ":drop table on a missing table reports the error and continues"
            `Quick test_drop_nonexistent_table_reports_error_and_continues;
          Alcotest.test_case
            ":create table with an empty column list reports a validate error"
            `Quick test_create_table_empty_column_list_reports_validate_error;
          Alcotest.test_case
            ":create table with an empty primary key list reports a validate \
             error"
            `Quick
            test_create_table_empty_primary_key_list_reports_validate_error;
          Alcotest.test_case
            ":create table with a duplicate column reports a validate error"
            `Quick test_create_table_duplicate_column_reports_validate_error;
          Alcotest.test_case
            ":create table whose primary key names an unknown column reports a \
             validate error"
            `Quick
            test_create_table_primary_key_unknown_column_reports_validate_error;
          Alcotest.test_case
            ":create table whose primary key repeats a column reports a \
             validate error"
            `Quick
            test_create_table_duplicate_primary_key_column_reports_validate_error;
          Alcotest.test_case
            ":create table followed by list/type/drop/list round-trips" `Quick
            test_create_table_end_to_end_sequence;
          Alcotest.test_case
            ":create table on an existing table reports the error and continues"
            `Quick test_create_table_already_exists_reports_error_and_continues;
        ] );
    ]
