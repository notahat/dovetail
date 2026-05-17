(** Unit tests for [Doctest], the markdown REPL-session extractor and verifier.
*)

open Dovetail
open Test_helpers

(** Extract sessions from [markdown] and assert exactly [n] came out. *)
let extract_expecting_count ~count markdown =
  let sessions = Doctest.extract_sessions markdown in
  Alcotest.(check int) "session count" count (List.length sessions);
  sessions

(** Assert a query's source and expected output match the supplied values. *)
let check_query ~source ~expected_output (query : Doctest.query) =
  Alcotest.(check string) "query source" source query.source;
  Alcotest.(check string)
    "expected output" expected_output query.expected_output

let test_block_starting_with_prompt_is_recognised () =
  let markdown =
    {|Some prose.

```
> users
expected line one
expected line two
```

Trailing prose.
|}
  in
  match extract_expecting_count ~count:1 markdown with
  | [ session ] -> (
      Alcotest.(check int) "queries in session" 1 (List.length session.queries);
      match session.queries with
      | [ query ] ->
          check_query ~source:"users"
            ~expected_output:"expected line one\nexpected line two\n" query
      | _ -> Alcotest.fail "expected exactly one query")
  | _ -> Alcotest.fail "expected exactly one session"

let test_block_not_starting_with_prompt_is_ignored () =
  let markdown =
    {|Intro.

```ocaml
let answer = 42
```

```
not a prompt line
> too late to count
```

Outro.
|}
  in
  let _ = extract_expecting_count ~count:0 markdown in
  ()

let test_session_with_multiple_queries_splits () =
  let markdown = {|```
> users
row one
row two
> orders
order one
```
|} in
  match extract_expecting_count ~count:1 markdown with
  | [ session ] -> (
      Alcotest.(check int) "queries in session" 2 (List.length session.queries);
      match session.queries with
      | [ first; second ] ->
          check_query ~source:"users" ~expected_output:"row one\nrow two\n"
            first;
          check_query ~source:"orders" ~expected_output:"order one\n" second
      | _ -> Alcotest.fail "expected exactly two queries")
  | _ -> Alcotest.fail "expected exactly one session"

let test_document_with_no_sessions_returns_empty () =
  let markdown = {|Plain prose.

Another paragraph, no fences.
|} in
  let _ = extract_expecting_count ~count:0 markdown in
  ()

let test_mismatch_reports_query_and_actual_output () =
  let markdown = {|```
> users
this is deliberately wrong
```
|} in
  let sessions = Doctest.extract_sessions markdown in
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  match Doctest.verify_sessions environment sessions with
  | Ok () ->
      Alcotest.fail "expected a doctest mismatch, but verification succeeded"
  | Error error ->
      Alcotest.(check string)
        "mismatch carries the original query" "users" error.query.source;
      if not (contains_substring error.actual_output "Alice") then
        Alcotest.failf
          "expected actual output to contain a fixture marker (Alice)\n\
           --- actual ---\n\
           %s"
          error.actual_output

let () =
  Alcotest.run "doctest"
    [
      ( "extractor",
        [
          Alcotest.test_case "a fenced block starting with > is a session"
            `Quick test_block_starting_with_prompt_is_recognised;
          Alcotest.test_case "a fenced block not starting with > is ignored"
            `Quick test_block_not_starting_with_prompt_is_ignored;
          Alcotest.test_case
            "a session with multiple > lines splits into multiple queries"
            `Quick test_session_with_multiple_queries_splits;
          Alcotest.test_case
            "a document with no sessions extracts an empty list" `Quick
            test_document_with_no_sessions_returns_empty;
        ] );
      ( "verifier",
        [
          Alcotest.test_case
            "a mismatch is reported with its query and the actual output" `Quick
            test_mismatch_reports_query_and_actual_output;
        ] );
    ]
