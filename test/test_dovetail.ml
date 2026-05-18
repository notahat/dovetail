(** Integration test for the [dovetail] binary.

    Spawns the binary as a subprocess with a scripted stdin, an isolated LMDB
    environment in a temp directory, and verifies the expected pretty-printed
    rows appear in stdout. This is the only test that exercises argv parsing,
    the Storage env lifecycle, and the stdin/stdout adapters together. *)

open Test_helpers

(** Path to the built dovetail binary, relative to the test runner's working
    directory under [_build/default/test/]. *)
let binary_path = "../bin/main.exe"

(** Run [binary_path] with [environment_path] as its argument, sending
    [stdin_text] as standard input. The [--demo-data] flag is passed so the
    example tables are seeded before the REPL takes over -- this test fixes the
    binary's read path against known rows. Returns the captured stdout as a
    string. Asserts the binary exited cleanly (code 0); on non-zero, signal, or
    stop, fails the test with stderr included so the failure mode is visible. *)
let run_binary ~environment_path ~stdin_text =
  let environment_variables = Unix.environment () in
  let argv = [| binary_path; "--demo-data"; environment_path |] in
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
  let stdout_text = run_binary ~environment_path ~stdin_text:"users\n" in
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
      ~stdin_text:"users | join orders on users.id = orders.user_id\n"
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
        ] );
    ]
