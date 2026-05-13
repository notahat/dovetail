(** Shared test fixtures and helpers.

    Covers four overlapping concerns:

    - Scope-bound resources ({!with_temp_dir}, {!with_environment}) in the
      {!Fun.protect} style, guaranteeing cleanup whether the body returns
      normally or raises.
    - Fixture-row constants matching what {!Fixture.populate_if_empty} writes,
      for tests that need to compare query results against a single shared
      expectation.
    - [Expression.t] constructors ({!predicate_column}, {!predicate_compare}, …)
      that read close to the predicate's source form at the call site.
    - Pipeline-integration helpers ({!with_query_result}, {!with_query_failure})
      that run a query through parse / lower / translate / eval, so end-to-end
      tests don't have to restate the boilerplate. *)

open Dovetail

(** Recursively remove [path]. Uses [lstat] so symlinks are unlinked rather than
    followed. Raises through any underlying [Unix] error. *)
let rec remove_recursive path =
  match (Unix.lstat path).st_kind with
  | S_DIR ->
      Sys.readdir path
      |> Array.iter (fun entry -> remove_recursive (Filename.concat path entry));
      Unix.rmdir path
  | _ -> Unix.unlink path

(** [with_temp_dir f] creates a fresh, uniquely-named temp directory, runs [f]
    with its path, and removes the directory on exit. The directory name
    includes the pid and a random number so concurrent test runs don't collide.

    Cleanup is unconditional: it runs whether [f] returns normally or raises,
    via {!Fun.protect}. *)
let with_temp_dir f =
  let base = Filename.get_temp_dir_name () in
  let unique_name =
    Printf.sprintf "dovetail-test-%d-%d" (Unix.getpid ()) (Random.bits ())
  in
  let directory = Filename.concat base unique_name in
  Unix.mkdir directory 0o755;
  Fun.protect
    ~finally:(fun () -> remove_recursive directory)
    (fun () -> f directory)

(** [with_environment path f] opens an LMDB environment at [path], runs
    [f environment], and closes the environment on exit. *)
let with_environment path f =
  let environment = Storage.open_environment path in
  Fun.protect
    ~finally:(fun () -> Storage.close_environment environment)
    (fun () -> f environment)

(** The five [users] fixture rows as [Schema.tuple]s, in primary-key order.
    Mirrors [Fixture.users_rows] but lives here so tests can compare pipeline
    output against a single shared expectation. *)
let expected_users_rows : Schema.tuple list =
  [
    [|
      Value.Int64 1L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 2L;
      Value.String "Bob";
      Value.String "bob@example.com";
      Value.Bool false;
    |];
    [|
      Value.Int64 3L;
      Value.String "Carol";
      Value.String "carol@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 4L;
      Value.String "Dave";
      Value.String "dave@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 5L;
      Value.String "Eve";
      Value.String "eve@example.com";
      Value.Bool false;
    |];
  ]

(** The six [orders] fixture rows as [Schema.tuple]s, in primary-key order.
    Mirrors [Fixture.orders_rows] but lives here so tests can compare pipeline
    output against a single shared expectation. Dave (user id 4) deliberately
    has no orders; Alice (id 1) and Carol (id 3) each have two. *)
let expected_orders_rows : Schema.tuple list =
  [
    [| Value.Int64 1L; Value.Int64 1L; Value.String "Coffee"; Value.Int64 5L |];
    [| Value.Int64 2L; Value.Int64 1L; Value.String "Bagel"; Value.Int64 4L |];
    [| Value.Int64 3L; Value.Int64 2L; Value.String "Tea"; Value.Int64 3L |];
    [|
      Value.Int64 4L; Value.Int64 3L; Value.String "Sandwich"; Value.Int64 8L;
    |];
    [| Value.Int64 5L; Value.Int64 3L; Value.String "Cake"; Value.Int64 6L |];
    [| Value.Int64 6L; Value.Int64 5L; Value.String "Cookie"; Value.Int64 2L |];
  ]

(** Alcotest testable for a list of [Schema.tuple]s. Polymorphic-equality based;
    the printer is a placeholder because tuples don't have a natural one-line
    rendering and the diff machinery isn't worth the weight here. *)
let tuple_list_testable : Schema.tuple list Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<tuples>")) ( = )

(** Build a bare (unqualified) [Schema.column_reference]. *)
let column_reference name : Schema.column_reference = { qualifier = None; name }

(** Build a qualified [Schema.column_reference]. *)
let qualified_column_reference ~qualifier ~name : Schema.column_reference =
  { qualifier = Some qualifier; name }

(** An [Expression.t] referring to a bare (unqualified) column. *)
let predicate_column name : Expression.t = Column (column_reference name)

(** An [Expression.t] referring to a qualified column. *)
let predicate_qualified_column ~qualifier ~name : Expression.t =
  Column (qualified_column_reference ~qualifier ~name)

(** An [Expression.t] wrapping a literal value. *)
let predicate_literal value : Expression.t = Literal value

(** An [Expression.t] comparing two sub-expressions. The keyword arguments
    mirror the record fields so the call site reads close to the predicate's
    source form. *)
let predicate_compare ~left ~op ~right : Expression.t =
  Compare { left; op; right }

(** An [Expression.t] composing two predicates with logical AND. *)
let predicate_and ~left ~right : Expression.t = And (left, right)

(** An [Expression.t] composing two predicates with logical OR. *)
let predicate_or ~left ~right : Expression.t = Or (left, right)

(** An [Expression.t] negating a predicate. *)
let predicate_not operand : Expression.t = Not operand

(** [with_query_result query check_rows] runs [query] through the full parse /
    lower / translate / eval pipeline against the standard fixture and calls
    [check_rows] with the resulting list of tuples. The temp directory, LMDB
    environment, fixture population, and read transaction are all set up and
    torn down around the call. *)
let with_query_result query check_rows =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse query with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          check_rows (List.of_seq relation.tuples)))

(** [with_query_failure ~label ~expected query] runs [query] through the same
    pipeline as {!with_query_result} but asserts that [Eval.eval] raises
    [expected]. [label] is the description shown in test output. *)
let with_query_failure ~label ~expected query =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse query with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Alcotest.check_raises label expected (fun () ->
          Eval.eval environment transaction physical (fun _relation -> ())))

(** [contains_substring haystack needle] is [true] if [needle] appears anywhere
    in [haystack]. Avoids pulling in [Str] for one-off checks. *)
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
