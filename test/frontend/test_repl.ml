(** Tests for [Repl]. *)

open Dovetail_frontend
open Test_helpers
module Plan = Dovetail_plan

(** Run the REPL against a populated environment with [lines] as input,
    capturing all formatter output as a string. [show_physical] defaults to
    [false], matching the binary's default. *)
let run_with_input ?(show_physical = false) lines =
  with_fixture_environment @@ fun environment ->
  with_captured_formatter @@ fun formatter ->
  Repl.run ~show_physical environment
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

(* A hand-built insert mutation used only as a constructor witness for the
   render-status tests below. The source plan is irrelevant -- the renderer
   keys off the mutation constructor for the verb and never touches [source]. *)
let example_insert : Plan.Physical.mutation =
  Insert
    {
      table = "orders";
      source = Plan.Physical.RelationLiteral { columns = []; rows = [ [] ] };
    }

let test_format_mutation_status_singular_row () =
  Alcotest.(check string)
    "one row uses the singular noun" "inserted 1 row"
    (Repl.format_mutation_status example_insert 1)

let test_format_mutation_status_zero_rows_pluralises () =
  Alcotest.(check string)
    "zero rows uses the plural noun" "inserted 0 rows"
    (Repl.format_mutation_status example_insert 0)

let test_format_mutation_status_many_rows_pluralises () =
  Alcotest.(check string)
    "many rows use the plural noun" "inserted 5 rows"
    (Repl.format_mutation_status example_insert 5)

(* End-to-end: a user-typed insert pipeline runs through parse / lower /
   translate / eval, commits the row inside a write transaction, and
   prints the affected-row status line. The follow-up restrict query
   confirms the row landed in storage and is readable. *)
let test_insert_into_orders_writes_row_and_reports_status () =
  let output =
    run_with_input
      [
        "{id: 9, user_id: 1, description: \"Pretzel\", amount: 9} | insert \
         into orders";
        "orders | restrict id = 9";
      ]
  in
  check_contains "insert status line" output "inserted 1 row";
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

(* End-to-end: [:describe <name>] parses, classifies
   as a read, looks the schema up in the catalog inside a read
   transaction, and prints the canonical form via [Format.statement] on
   the [Statement.of_schema] adapter. The fixture seeds [users] with
   four fields and a single-column primary key, so the output matches
   the design doc's canonical form verbatim. *)
let test_describe_prints_canonical_form_for_fixture_table () =
  let output = run_with_input [ ":describe users" ] in
  check_contains ":describe canonical form" output
    ":create table users (\n\
    \  id: Int64,\n\
    \  name: String,\n\
    \  email: String,\n\
    \  active: Bool,\n\
     ) primary key (id)"

(* The "no such table" error path for describe: the executor raises with
   the [DDL: describe ...: no such table] prefix, the REPL catches it
   via its generic error guard, and the loop continues. *)
let test_describe_nonexistent_table_reports_error_and_continues () =
  let output = run_with_input [ ":describe nonexistent"; ":list tables" ] in
  check_contains "no-such-table error" output
    "DDL: describe \"nonexistent\": no such table";
  check_contains "loop continues after describe error" output "users";
  check_contains "loop continues after describe error" output "orders"

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
   describes [widgets] (the canonical form matches the input the user
   typed verbatim), drops it, and lists again (it is gone). The fixture
   tables (orders, users) remain present throughout so the test also
   sees that the create did not disturb the sibling tables. *)
let test_create_table_end_to_end_sequence () =
  let output =
    run_with_input
      [
        ":create table widgets (id: Int64, name: String) primary key (id)";
        ":list tables";
        ":describe widgets";
        ":drop table widgets";
        ":list tables";
      ]
  in
  check_contains "create status line" output "created table \"widgets\"";
  check_contains ":describe widgets canonical form" output
    ":create table widgets (\n  id: Int64,\n  name: String,\n) primary key (id)";
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
          Alcotest.test_case
            "a bare relation literal prints as a one-row relation" `Quick
            test_relation_literal_alone_prints_one_row;
          Alcotest.test_case
            "insert into orders writes the row and prints the status line"
            `Quick test_insert_into_orders_writes_row_and_reports_status;
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
            ":describe prints the canonical form for a fixture table" `Quick
            test_describe_prints_canonical_form_for_fixture_table;
          Alcotest.test_case
            ":describe on a missing table reports the error and continues"
            `Quick test_describe_nonexistent_table_reports_error_and_continues;
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
            ":create table followed by list/describe/drop/list round-trips"
            `Quick test_create_table_end_to_end_sequence;
          Alcotest.test_case
            ":create table on an existing table reports the error and continues"
            `Quick test_create_table_already_exists_reports_error_and_continues;
        ] );
      ( "mutation rendering",
        [
          Alcotest.test_case "one affected row uses the singular noun" `Quick
            test_format_mutation_status_singular_row;
          Alcotest.test_case "zero affected rows uses the plural noun" `Quick
            test_format_mutation_status_zero_rows_pluralises;
          Alcotest.test_case "many affected rows use the plural noun" `Quick
            test_format_mutation_status_many_rows_pluralises;
        ] );
    ]
