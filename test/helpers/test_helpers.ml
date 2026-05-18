(** Shared test fixtures and helpers.

    Covers five overlapping concerns:

    - Scope-bound resources ({!with_temp_dir}, {!with_environment},
      {!with_fixture_environment}) in the {!Fun.protect} style, guaranteeing
      cleanup whether the body returns normally or raises.
    - Output and input capture ({!with_captured_formatter},
      {!read_line_from_list}) for tests that exercise {!Repl.run} or any other
      formatter-driven code.
    - Fixture-row constants matching what {!Fixture.populate_if_empty} writes,
      for tests that need to compare query results against a single shared
      expectation.
    - [Expression.t] constructors ({!expression_column}, {!expression_compare},
      …) that read close to the expression's source form at the call site.
    - Pipeline-integration helpers ({!with_query_result}, {!with_query_failure})
      that run a query through parse / lower / translate / eval, so end-to-end
      tests don't have to restate the boilerplate. *)

open Dovetail
open Dovetail_core

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

(** [with_fixture_environment f] creates a temp directory, opens an LMDB
    environment in it, populates the standard fixture, runs [f environment], and
    tears everything down on exit. Composes {!with_temp_dir},
    {!with_environment}, and {!Fixture.populate_if_empty} -- the shape every
    integration test that touches storage and expects fixture data starts with.
*)
let with_fixture_environment f =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  f environment

(** [with_demo_seeded_environment f] creates a temp directory, opens an LMDB
    environment in it, seeds the demo tables through the surface DDL/DML path
    via {!Demo_data.run}, runs [f environment], and tears everything down on
    exit. Mirrors {!with_fixture_environment} but exercises the documentation
    doctests through the same path users hit at the REPL with [--demo-data], so
    a DDL or DML regression shows up in the doctest suite immediately. *)
let with_demo_seeded_environment f =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Demo_data.run environment;
  f environment

(** [with_captured_formatter write_to_formatter] runs [write_to_formatter]
    against a fresh buffered formatter, flushes it, and returns the captured
    string. The shape every test that compares formatted output (REPL
    transcripts, [Relation.print] renderings, plan dumps) starts with. *)
let with_captured_formatter write_to_formatter =
  let buffer = Buffer.create 512 in
  let formatter = Format.formatter_of_buffer buffer in
  write_to_formatter formatter;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

(** [read_line_from_list lines] returns a [unit -> string option] callback
    suitable for {!Repl.run}'s [~read_line] argument. Each call returns the next
    string in [lines]; once exhausted, every call returns [None] (mirroring the
    contract a real stdin closure has at EOF). *)
let read_line_from_list lines =
  let remaining = ref lines in
  fun () ->
    match !remaining with
    | [] -> None
    | head :: rest ->
        remaining := rest;
        Some head

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

(** Format a tuple's values using {!Value.format}, comma-separated and wrapped
    in brackets. So {[Alcotest]} failure diffs read as
    [\[1, "Alice", true\]] -- the boundaries between values are visible, the
    kinds are distinguishable at a glance. *)
let format_tuple formatter tuple =
  Format.fprintf formatter "[";
  Array.iteri
    (fun index value ->
      if index > 0 then Format.fprintf formatter ", ";
      Value.format formatter value)
    tuple;
  Format.fprintf formatter "]"

(** Format a list of tuples one per line, in input order. Alcotest's diff
    machinery does a line-oriented comparison of the rendered strings, so
    per-row newlines mean a mismatch shows up as a single-row delta rather than
    the whole list. *)
let format_tuple_list formatter tuples =
  List.iter
    (fun tuple -> Format.fprintf formatter "%a@\n" format_tuple tuple)
    tuples

(** Alcotest testable for a list of [Schema.tuple]s. Polymorphic-equality based.
    The printer renders one tuple per line using {!Value.format} so failure
    diffs surface the offending row rather than [\<tuples\> vs \<tuples\>]. *)
let tuple_list_testable : Schema.tuple list Alcotest.testable =
  Alcotest.testable format_tuple_list ( = )

(** Alcotest testable for a [Physical.t]. Polymorphic-equality based; the
    printer is {!Physical.format}, so failure diffs show the EXPLAIN-style
    operator tree for both expected and actual plans. *)
let physical_testable : Physical.t Alcotest.testable =
  Alcotest.testable Physical.format ( = )

(** Extract the relation sub-plan from a [Physical.plan] that is known to be a
    [Query]. The translate tests use this to keep their assertions focused on
    the rewrite-recognised inner plan; [Physical.plan]'s wrapper shape is pinned
    by [Translate.translate]'s type signature, so no value-level check of the
    wrapper is needed. A [Mutation] reaching this helper would be a
    translate-side bug -- the parser path for mutations doesn't land until step
    4 -- so we abort the test loudly. *)
let unwrap_query (plan : Physical.plan) : Physical.t =
  match plan with
  | Query plan -> plan
  | Mutation _ -> Alcotest.fail "expected a Query plan, got a Mutation"

(** Extract the relation sub-plan from a [Logical.plan] that is known to be a
    [Query]. Sibling to {!unwrap_query} for the Logical side: the Lower tests
    use this to keep their structural assertions aimed at the relation tree
    while [Lower.lower]'s wrapper shape is pinned by its type signature. A
    [Mutation] reaching this helper would mean the Ast somehow produced one,
    which is impossible until slice 11 step 4 wires the sink production. *)
let unwrap_logical_query (plan : Logical.plan) : Logical.t =
  match plan with
  | Query plan -> plan
  | Mutation _ ->
      Alcotest.fail "expected a Logical.Query plan, got a Logical.Mutation"

(** Build a bare (unqualified) [Schema.column_reference]. *)
let column_reference name : Schema.column_reference = { qualifier = None; name }

(** Build a qualified [Schema.column_reference]. *)
let qualified_column_reference ~qualifier ~name : Schema.column_reference =
  { qualifier = Some qualifier; name }

(** An [Expression.t] referring to a bare (unqualified) column. *)
let expression_column name : Expression.t = Column (column_reference name)

(** An [Expression.t] referring to a qualified column. *)
let expression_qualified_column ~qualifier ~name : Expression.t =
  Column (qualified_column_reference ~qualifier ~name)

(** An [Expression.t] wrapping a literal value. *)
let expression_literal value : Expression.t = Literal value

(** An [Expression.t] comparing two sub-expressions. The keyword arguments
    mirror the record fields so the call site reads close to the expression's
    source form. *)
let expression_compare ~left ~op ~right : Expression.t =
  Compare { left; op; right }

(** An [Expression.t] composing two sub-expressions with logical AND. *)
let expression_and ~left ~right : Expression.t = And (left, right)

(** An [Expression.t] composing two sub-expressions with logical OR. *)
let expression_or ~left ~right : Expression.t = Or (left, right)

(** An [Expression.t] negating a sub-expression. *)
let expression_not operand : Expression.t = Not operand

(** A catalog callback that knows about no tables. Use in [Translate]-level unit
    tests that don't exercise schema-dependent rewrites; the catalog is
    consulted only for [IndexLookup] recognition, so a [None]-everywhere
    callback yields the same translation as the slice-5 era did. *)
let noop_catalog : string -> Schema.t option = fun _table_name -> None

(** Build a catalog callback bound to [environment] and [transaction] so that
    [Translate] sees the real fixture schemas. Used by the pipeline-integration
    helpers below and any other test that wants the catalog wired up. *)
let make_catalog environment transaction table_name =
  Catalog.get environment transaction ~table_name

(** [with_query_result query check_rows] runs [query] through the full parse /
    lower / translate / eval pipeline against the standard fixture and calls
    [check_rows] with the resulting list of tuples. The temp directory, LMDB
    environment, fixture population, and read transaction are all set up and
    torn down around the call. *)
let with_query_result query check_rows =
  with_fixture_environment @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse query with
        | Ok (Ast.Pipeline plan) -> plan
        | Ok (Ast.Ddl _) ->
            Alcotest.failf "expected a pipeline but got a DDL statement: %s"
              query
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = unwrap_query (Translate.translate ~catalog logical) in
      Eval.eval environment transaction physical (fun relation ->
          check_rows (List.of_seq relation.tuples)))

(** [with_query_failure ~label ~expected query] runs [query] through the same
    pipeline as {!with_query_result} but asserts that [Eval.eval] raises
    [expected]. [label] is the description shown in test output. *)
let with_query_failure ~label ~expected query =
  with_fixture_environment @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse query with
        | Ok (Ast.Pipeline plan) -> plan
        | Ok (Ast.Ddl _) ->
            Alcotest.failf "expected a pipeline but got a DDL statement: %s"
              query
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = unwrap_query (Translate.translate ~catalog logical) in
      Alcotest.check_raises label expected (fun () ->
          Eval.eval environment transaction physical (fun _relation -> ())))

(** [evaluate_against_fixture plan] populates the standard fixture and evaluates
    [plan] inside a read transaction, returning the resulting schema and tuples.
    The temp directory, LMDB environment, fixture population, and read
    transaction are all set up and torn down around the call. *)
let evaluate_against_fixture plan =
  with_fixture_environment @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction plan (fun relation ->
          (relation.schema, List.of_seq relation.tuples)))

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

(** [count_substring haystack needle] is the number of (possibly overlapping)
    occurrences of [needle] in [haystack]. Returns [0] when [needle] is empty or
    longer than [haystack]. Useful when an assertion needs to count occurrences
    rather than test for presence -- e.g. checking that a table name appears in
    exactly one listing block of a REPL transcript. *)
let count_substring haystack needle =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  if needle_length = 0 || needle_length > haystack_length then 0
  else
    let limit = haystack_length - needle_length in
    let rec scan position count =
      if position > limit then count
      else if String.sub haystack position needle_length = needle then
        scan (position + 1) (count + 1)
      else scan (position + 1) count
    in
    scan 0 0
