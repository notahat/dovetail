(** End-to-end doctest verification for project markdown.

    Each markdown path in [verified_files] is parsed for REPL sessions, run
    through {!Repl.run} against a fresh demo-data-seeded environment, and
    asserted to match its documented expected output. The seeding goes through
    the public DDL/DML surface (the same path the [--demo-data] flag exercises
    at the binary), so a regression in DDL or DML lands as a doctest failure
    here rather than passing silently against a low-level-seeded fixture. *)

open Test_helpers

(** Markdown files that participate in doctest verification. Paths are resolved
    relative to the test runner's working directory under
    [_build/default/test/integration/], and the corresponding [(deps)] entries
    in [test/integration/dune] mirror each file into the build tree. *)
let verified_files =
  [
    "../../docs/query-language.md";
    "../../docs/query-language-tutorial.md";
    "../../docs/query-language-pipeline-operators.md";
    "../../docs/query-language-expressions.md";
    "../../docs/query-language-data-definition.md";
    "../../README.md";
  ]

(** Verify one markdown file end to end: spin up a fresh environment, seed the
    demo tables, hand both off to {!Doctest.verify_file}, fail with a
    descriptive error on any mismatch. *)
let verify_one markdown_path () =
  with_demo_seeded_environment @@ fun environment ->
  match Doctest.verify_file environment ~markdown_path with
  | Ok () -> ()
  | Error error -> Alcotest.fail (Doctest.format_error ~markdown_path error)

let () =
  let cases =
    List.map
      (fun markdown_path ->
        Alcotest.test_case
          (Printf.sprintf "%s verifies clean against the demo-seeded env"
             markdown_path)
          `Slow (verify_one markdown_path))
      verified_files
  in
  Alcotest.run "documentation" [ ("doctest", cases) ]
