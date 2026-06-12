(** Unit tests for [Doctest], the markdown REPL-session extractor and verifier.
*)

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

let test_sql_prompt_block_is_recognised_as_sql_session () =
  let markdown =
    {|```
sql> SELECT name FROM users WHERE id = 1
 name
-------
 Alice
(1 row)
```
|}
  in
  match extract_expecting_count ~count:1 markdown with
  | [ session ] -> (
      (match session.surface with
      | `Sql -> ()
      | `Ra -> Alcotest.fail "expected the session to carry the SQL surface");
      match session.queries with
      | [ query ] ->
          check_query ~source:"SELECT name FROM users WHERE id = 1"
            ~expected_output:" name\n-------\n Alice\n(1 row)\n" query
      | _ -> Alcotest.fail "expected exactly one query")
  | _ -> Alcotest.fail "expected exactly one session"

let test_each_block_carries_its_own_surface () =
  let markdown =
    {|```
> users
some rows
```

```
sql> SELECT * FROM users
some table
```
|}
  in
  match extract_expecting_count ~count:2 markdown with
  | [ first; second ] -> (
      (match first.surface with
      | `Ra -> ()
      | `Sql -> Alcotest.fail "expected the first session on the RA surface");
      match second.surface with
      | `Sql -> ()
      | `Ra -> Alcotest.fail "expected the second session on the SQL surface")
  | _ -> Alcotest.fail "expected exactly two sessions"

let test_trailing_ellipsis_accepts_extra_actual_rows () =
  (* `users` prints a relation literal with five rows. The doc here
     shows the preamble and only the first two rows followed by `...`,
     which should be treated as "anything that follows in actual output
     is accepted without further checking." *)
  let markdown =
    {|```
> users
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice", users.email = "alice@example.com", users.active = true),
  (users.id = 2, users.name = "Bob", users.email = "bob@example.com", users.active = false),
...
```
|}
  in
  let sessions = Doctest.extract_sessions markdown in
  with_fixture_environment @@ fun environment ->
  match Doctest.verify_sessions environment sessions with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf
        "expected truncation marker to accept trailing actual rows\n\
         --- actual ---\n\
         %s"
        error.actual_output

let test_ellipsis_only_recognised_on_its_own_line () =
  (* `...` appearing inside a row (here, as a substring of a name)
     must not be interpreted as the truncation marker. *)
  let markdown =
    {|```
> users
relation (users.id: int64, users.name: string, users.email: string, users.active: bool, primary key (id)) {
  (users.id = 1, users.name = "Alice ...", users.email = "alice@example.com", users.active = true),
```
|}
  in
  let sessions = Doctest.extract_sessions markdown in
  with_fixture_environment @@ fun environment ->
  match Doctest.verify_sessions environment sessions with
  | Ok () ->
      Alcotest.fail
        "expected mismatch: '...' embedded in a row is not a truncation marker"
  | Error _ -> ()

let test_sql_session_verifies_through_the_sql_surface () =
  (* The expected output is the SQL surface's psql-style table, captured
     from the binary. The renderer emits trailing spaces, which editors
     tend to strip from source files, so the block is built from quoted
     strings rather than written as one literal. On the RA surface the
     query line would be a parse error, so a pass proves the session ran
     on the surface its prompt names. *)
  let markdown =
    String.concat "\n"
      [
        "```";
        "sql> SELECT name FROM users WHERE id = 1";
        " name  ";
        "-------";
        " Alice ";
        "(1 row)";
        "```";
        "";
      ]
  in
  let sessions = Doctest.extract_sessions markdown in
  with_fixture_environment @@ fun environment ->
  match Doctest.verify_sessions environment sessions with
  | Ok () -> ()
  | Error error ->
      Alcotest.failf
        "expected the SQL session to verify through the SQL surface\n\
         --- actual ---\n\
         %s"
        error.actual_output

let test_mismatch_reports_query_and_actual_output () =
  let markdown = {|```
> users
this is deliberately wrong
```
|} in
  let sessions = Doctest.extract_sessions markdown in
  with_fixture_environment @@ fun environment ->
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
          Alcotest.test_case
            "a fenced block starting with sql> is a session on the SQL surface"
            `Quick test_sql_prompt_block_is_recognised_as_sql_session;
          Alcotest.test_case "each block carries its own surface" `Quick
            test_each_block_carries_its_own_surface;
        ] );
      ( "verifier",
        [
          Alcotest.test_case
            "a mismatch is reported with its query and the actual output" `Quick
            test_mismatch_reports_query_and_actual_output;
          Alcotest.test_case "a trailing ... line accepts extra actual rows"
            `Quick test_trailing_ellipsis_accepts_extra_actual_rows;
          Alcotest.test_case "... is only recognised on its own line" `Quick
            test_ellipsis_only_recognised_on_its_own_line;
          Alcotest.test_case "an sql> session verifies through the SQL surface"
            `Quick test_sql_session_verifies_through_the_sql_surface;
        ] );
    ]
