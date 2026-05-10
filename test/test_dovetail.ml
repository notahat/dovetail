(** Integration test for the [dovetail] binary.

    Spawns the binary as a subprocess with a scripted stdin, an isolated LMDB
    environment in a temp directory, and verifies the expected pretty-printed
    rows appear in stdout. This is the only test that exercises argv parsing,
    the Storage env lifecycle, and the stdin/stdout adapters together. *)

open Test_helpers

(** Path to the built dovetail binary, relative to the test runner's working
    directory under [_build/default/test/]. *)
let binary_path = "../bin/main.exe"

let contains_substring haystack needle =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  if needle_length = 0 then true
  else if needle_length > haystack_length then false
  else
    let limit = haystack_length - needle_length in
    let rec scan position =
      if position > limit then false
      else if String.sub haystack position needle_length = needle then true
      else scan (position + 1)
    in
    scan 0

(** Run [binary_path] with [environment_path] as its argument, sending
    [stdin_text] as standard input. Returns the captured stdout as a string.
    Stderr is discarded; the binary doesn't write to it on success and we don't
    depend on its content. *)
let run_binary ~environment_path ~stdin_text =
  let environment_variables = Unix.environment () in
  let argv = [| binary_path; environment_path |] in
  let stdout_chan, stdin_chan, stderr_chan =
    Unix.open_process_args_full binary_path argv environment_variables
  in
  output_string stdin_chan stdin_text;
  close_out stdin_chan;
  let stdout_text = In_channel.input_all stdout_chan in
  let _ = In_channel.input_all stderr_chan in
  let _ = Unix.close_process_full (stdout_chan, stdin_chan, stderr_chan) in
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

let () =
  Alcotest.run "dovetail"
    [
      ( "binary",
        [
          Alcotest.test_case "users query prints fixture rows to stdout" `Slow
            test_users_query_prints_fixture_rows;
        ] );
    ]
