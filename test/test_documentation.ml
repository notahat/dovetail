(** End-to-end doctest verification for project markdown.

    Each markdown path in [verified_files] is parsed for REPL sessions, run
    through {!Repl.run} against a fresh fixture-populated environment, and
    asserted to match its documented expected output. *)

open Dovetail
open Test_helpers

(** Markdown files that participate in doctest verification. Paths are resolved
    relative to the test runner's working directory under
    [_build/default/test/], and the corresponding [(deps)] entries in
    [test/dune] mirror each file into the build tree. *)
let verified_files = [ "../docs/query-language.md" ]

(** Verify one markdown file end to end: spin up a fresh environment, populate
    the fixture, hand both off to {!Doctest.verify_file}, fail with a
    descriptive error on any mismatch. *)
let verify_one markdown_path () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  match Doctest.verify_file environment ~markdown_path with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Doctest.format_error ~markdown_path error)

let () =
  let cases =
    List.map
      (fun markdown_path ->
        Alcotest.test_case
          (Printf.sprintf "%s verifies clean against the fixture" markdown_path)
          `Slow (verify_one markdown_path))
      verified_files
  in
  Alcotest.run "documentation" [ ("doctest", cases) ]
