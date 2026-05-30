(** Integration test for the [dovetail] binary.

    Spawns the binary as a subprocess with a scripted stdin, an isolated LMDB
    environment in a temp directory, and verifies the expected pretty-printed
    rows appear in stdout. This is the only test that exercises argv parsing,
    the Storage env lifecycle, and the stdin/stdout adapters together. *)

open Test_helpers

(** Path to the built dovetail binary, relative to the test runner's working
    directory under [_build/default/test/integration/]. *)
let binary_path = "../../bin/main.exe"

(** Run [binary_path] with [environment_path] as its argument, sending
    [stdin_text] as standard input. The [--demo-data] flag is passed so the
    example tables are seeded before the REPL takes over -- this test fixes the
    binary's read path against known rows. Returns the captured stdout as a
    string. Asserts the binary exited cleanly (code 0); on non-zero, signal, or
    stop, fails the test with stderr included so the failure mode is visible. *)
let run_binary ?(extra_flags = []) ~environment_path ~stdin_text () =
  let environment_variables = Unix.environment () in
  let argv =
    Array.of_list
      ((binary_path :: "--demo-data" :: extra_flags) @ [ environment_path ])
  in
  let stdout_chan, stdin_chan, stderr_chan =
    Unix.open_process_args_full binary_path argv environment_variables
  in
  output_string stdin_chan stdin_text;
  close_out stdin_chan;
  let stdout_text = In_channel.input_all stdout_chan in
  let stderr_text = In_channel.input_all stderr_chan in
  let status = Unix.close_process_full (stdout_chan, stdin_chan, stderr_chan) in
  (match status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      Alcotest.failf "binary exited with code %d\n--- stderr ---\n%s" code
        stderr_text
  | Unix.WSIGNALED signal ->
      Alcotest.failf "binary killed by signal %d\n--- stderr ---\n%s" signal
        stderr_text
  | Unix.WSTOPPED signal ->
      Alcotest.failf "binary stopped by signal %d\n--- stderr ---\n%s" signal
        stderr_text);
  stdout_text

let test_users_query_prints_fixture_rows () =
  with_temp_dir @@ fun environment_path ->
  let stdout_text = run_binary ~environment_path ~stdin_text:"users\n" () in
  List.iter
    (fun name ->
      if not (contains_substring stdout_text name) then
        Alcotest.failf "expected stdout to contain %S\n--- stdout ---\n%s" name
          stdout_text)
    [ "Alice"; "Bob"; "Carol"; "Dave"; "Eve" ]

let test_users_join_orders_prints_matched_pairs () =
  with_temp_dir @@ fun environment_path ->
  let stdout_text =
    run_binary ~environment_path
      ~stdin_text:"users | join orders on users.id = orders.user_id\n" ()
  in
  (* Dave (user 4) has no orders, so he must not appear; the other four
     buyers must each show up in the output. *)
  if contains_substring stdout_text "Dave" then
    Alcotest.failf
      "expected stdout to omit \"Dave\" (no matching orders)\n\
       --- stdout ---\n\
       %s"
      stdout_text;
  List.iter
    (fun name ->
      if not (contains_substring stdout_text name) then
        Alcotest.failf "expected stdout to contain %S\n--- stdout ---\n%s" name
          stdout_text)
    [ "Alice"; "Bob"; "Carol"; "Eve" ]

(* Helper used by the [create table] / [drop table] tests: assert that
   every expected substring appears in the captured stdout. *)
let expect_stdout_contains stdout_text expected_substrings =
  List.iter
    (fun expected ->
      if not (contains_substring stdout_text expected) then
        Alcotest.failf "expected stdout to contain %S\n--- stdout ---\n%s"
          expected stdout_text)
    expected_substrings

let test_create_table_empty_form_creates_and_reports () =
  with_temp_dir @@ fun environment_path ->
  let stdin_text =
    "(id: int64, name: string, primary key (id)) | create table widgets\n\
     catalog | tables\n"
  in
  let stdout_text = run_binary ~environment_path ~stdin_text () in
  expect_stdout_contains stdout_text [ "widgets"; "created" ]

let test_create_table_seeded_form_creates_and_seeds () =
  with_temp_dir @@ fun environment_path ->
  let stdin_text =
    "relation (id: int64, name: string, primary key (id)) { (id = 1, name = \
     \"alice\") } | create table greeters\n\
     greeters\n"
  in
  let stdout_text = run_binary ~environment_path ~stdin_text () in
  expect_stdout_contains stdout_text [ "greeters"; "created"; "alice" ]

let test_drop_table_leaf_drops_and_reports () =
  with_temp_dir @@ fun environment_path ->
  let stdin_text = "drop table orders\ncatalog | tables\n" in
  let stdout_text = run_binary ~environment_path ~stdin_text () in
  expect_stdout_contains stdout_text [ "orders"; "dropped" ]

(* The SQL surface, fully wired: launching with [--sql] selects it for the
   session, so [SELECT * FROM users] runs through parse / lower / translate /
   eval against the seeded fixture and prints the same rows the RA surface's
   [users] query does. *)
let test_sql_select_star_prints_fixture_rows () =
  with_temp_dir @@ fun environment_path ->
  let stdout_text =
    run_binary ~extra_flags:[ "--sql" ] ~environment_path
      ~stdin_text:"SELECT * FROM users\n" ()
  in
  expect_stdout_contains stdout_text
    [ "Alice"; "Bob"; "Carol"; "Dave"; "Eve"; "alice@example.com" ];
  (* The SQL surface renders a psql-style table: a dashed rule and a
     trailing row count, not the RA surface's relation-literal form. *)
  expect_stdout_contains stdout_text [ "---"; "(5 rows)" ];
  if contains_substring stdout_text "relation (" then
    Alcotest.failf
      "expected the SQL surface to render a table, not a relation literal\n\
       --- stdout ---\n\
       %s"
      stdout_text

(* A SQL query against a missing table reaches eval and reports the same
   [error:] the RA surface would; the session does not crash. *)
let test_sql_select_from_missing_table_reports_error () =
  with_temp_dir @@ fun environment_path ->
  let stdout_text =
    run_binary ~extra_flags:[ "--sql" ] ~environment_path
      ~stdin_text:"SELECT * FROM nonexistent\n" ()
  in
  expect_stdout_contains stdout_text [ "error:" ]

let () =
  Alcotest.run "dovetail"
    [
      ( "binary",
        [
          Alcotest.test_case "users query prints fixture rows to stdout" `Slow
            test_users_query_prints_fixture_rows;
          Alcotest.test_case
            "users join orders prints only matched (user, order) pairs" `Slow
            test_users_join_orders_prints_matched_pairs;
          Alcotest.test_case
            "[<type-expr> | create table <name>] creates the table" `Slow
            test_create_table_empty_form_creates_and_reports;
          Alcotest.test_case
            "[<relation-literal> | create table <name>] creates and seeds the \
             table"
            `Slow test_create_table_seeded_form_creates_and_seeds;
          Alcotest.test_case "[drop table <name>] drops the table" `Slow
            test_drop_table_leaf_drops_and_reports;
          Alcotest.test_case
            "[--sql] SELECT * FROM users prints fixture rows to stdout" `Slow
            test_sql_select_star_prints_fixture_rows;
          Alcotest.test_case "[--sql] SELECT * FROM <missing> reports an error"
            `Slow test_sql_select_from_missing_table_reports_error;
        ] );
    ]
