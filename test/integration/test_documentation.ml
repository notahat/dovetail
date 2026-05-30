(** End-to-end doctest verification for the project's markdown.

    Each markdown path in [verified_files] is parsed for REPL sessions, run
    through {!Repl.run} against a fresh demo-data-seeded environment, and
    asserted to match its documented expected output. The seeding goes through
    the public DDL/DML surface (the same path the [--demo-data] flag exercises
    at the binary), so a regression in DDL or DML lands as a doctest failure
    here rather than passing silently against a low-level-seeded fixture. *)

open Test_helpers

(** Lists the markdown files directly in [directory], sorted, as paths relative
    to the test runner's working directory. The doctest folders are mirrored
    into the build tree by the [glob_files] [(deps)] entries in
    [test/integration/dune], so reading the directory here picks up exactly the
    docs dune copied in -- a new reference file needs no edit to this test. *)
let markdown_files_in directory =
  Sys.readdir directory |> Array.to_list
  |> List.filter (fun file_name -> Filename.check_suffix file_name ".md")
  |> List.sort String.compare
  |> List.map (Filename.concat directory)

(** Markdown files that participate in doctest verification: every doc under the
    user-facing [tutorial/] and [reference/ra/] folders, plus the top-level
    README. Internals, design notes, and slice plans are excluded -- they carry
    no runnable REPL sessions.

    The SQL reference under [reference/sql/] is not yet listed: its examples use
    the [sql> ] prompt and the SQL surface, which {!Doctest} does not understand
    yet (it keys on [> ] and runs the relational-algebra surface). Its examples
    are hand-checked against the binary for now. TODO(sql-doctest): teach the
    harness the SQL surface, then add [reference/sql] here and to the
    [glob_files] dep in [dune]. *)
let verified_files =
  markdown_files_in "../../docs/tutorial"
  @ markdown_files_in "../../docs/reference/ra"
  @ [ "../../README.md" ]

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
