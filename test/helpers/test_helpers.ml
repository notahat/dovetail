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

module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term
module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Surface_ra = Dovetail_surface_ra
module Execution = Dovetail_execution
module Frontend = Dovetail_frontend

(* Re-export the sibling [Fixture] module so callers that [open Test_helpers]
   can write [Fixture.populate_if_empty] without qualifying the path. The
   library's main-module shape (this file matches the library name) means
   sub-modules are not lifted into the main module's scope automatically. *)
module Fixture = Fixture

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
  let environment = Storage.Engine.open_environment path in
  Fun.protect
    ~finally:(fun () -> Storage.Engine.close_environment environment)
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
  Frontend.Demo_data.run environment;
  f environment

(** [with_captured_formatter write_to_formatter] runs [write_to_formatter]
    against a fresh buffered formatter, flushes it, and returns the captured
    string. The shape every test that compares formatted output (REPL
    transcripts, [Relation.format] renderings, plan dumps) starts with. *)
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

(** The five [users] fixture rows. Re-binding of [Fixture.users_rows] so the ~22
    call sites that say [expected_users_rows] don't have to chase the module
    rename. *)
let expected_users_rows = Fixture.users_rows

(** The six [orders] fixture rows. Re-binding of [Fixture.orders_rows] so the
    ~22 call sites that say [expected_orders_rows] don't have to chase the
    module rename. Dave (user id 4) deliberately has no orders; Alice (id 1) and
    Carol (id 3) each have two. *)
let expected_orders_rows = Fixture.orders_rows

(** Format a row's values using {!Scalar.format}, comma-separated and wrapped in
    brackets. So {[Alcotest]} failure diffs read as [\[1, "Alice", true\]] --
    the boundaries between values are visible, the kinds are distinguishable at
    a glance. *)
let format_row formatter row =
  Format.fprintf formatter "[";
  Array.iteri
    (fun index value ->
      if index > 0 then Format.fprintf formatter ", ";
      Scalar.format formatter value)
    row;
  Format.fprintf formatter "]"

(** Format a list of rows one per line, in input order. Alcotest's diff
    machinery does a line-oriented comparison of the rendered strings, so
    per-row newlines mean a mismatch shows up as a single-row delta rather than
    the whole list. *)
let format_row_list formatter rows =
  List.iter (fun row -> Format.fprintf formatter "%a@\n" format_row row) rows

(** Alcotest testable for a list of [Row.value]s. Polymorphic-equality based.
    The printer renders one row per line using {!Scalar.format} so failure diffs
    surface the offending row rather than [\<rows\> vs \<rows\>]. *)
let row_list_testable : Row.value list Alcotest.testable =
  Alcotest.testable format_row_list ( = )

(** Alcotest testable for a [Physical.t]. Polymorphic-equality based; the
    printer is {!Physical.format}, so failure diffs show the EXPLAIN-style
    operator tree for both expected and actual plans. *)
let physical_testable : Plan.Physical.t Alcotest.testable =
  Alcotest.testable Plan.Physical.format ( = )

(** Build a bare (unqualified) [Surface_ra.Ast.column_reference]. *)
let column_reference name : Surface_ra.Ast.column_reference =
  { qualifier = None; name }

(** Build a qualified [Surface_ra.Ast.column_reference]. *)
let qualified_column_reference ~qualifier ~name :
    Surface_ra.Ast.column_reference =
  { qualifier = Some qualifier; name }

(** Build a bare (unqualified) [Row.column_reference]. Used in test sites that
    construct values at the logical / physical layers, where the column
    reference is still {!Row.column_reference}. *)
let row_column_reference name : Row.column_reference =
  { qualifier = None; name }

(** Build a qualified [Row.column_reference]. *)
let qualified_row_column_reference ~qualifier ~name : Row.column_reference =
  { qualifier = Some qualifier; name }

(** An [Expression.t] referring to a bare (unqualified) column. *)
let expression_column name : Expression.t = Column (row_column_reference name)

(** An [Expression.t] referring to a qualified column. *)
let expression_qualified_column ~qualifier ~name : Expression.t =
  Column (qualified_row_column_reference ~qualifier ~name)

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

(** [expect_relation callback term] applies [callback] to the relation inside
    [term], failing the running test with [Alcotest.fail] if [term] is the
    relation-kind arm instead. Wraps an existing relation-shaped callback for
    use against [Eval.eval], which hands its continuation a [Term.t]. *)
let expect_relation callback : [ `Set | `Bag ] Term.t -> 'a = function
  | Term.Relation_value relation -> callback relation
  | Term.Relation_kind _ | Term.Scalar_value _ | Term.Scalar_kind _
  | Term.Row_value _ | Term.Row_kind _ | Term.Catalog_value _
  | Term.Catalog_kind _ ->
      Alcotest.fail "expected a relation value but got a different term arm"

(** A catalog callback that knows about no tables. Use in [Translate]-level unit
    tests that don't exercise schema-dependent rewrites; the catalog is
    consulted only for [IndexLookup] recognition, so a [None]-everywhere
    callback yields a catalog-free translation. *)
let noop_catalog : string -> Relation.kind option = fun _table_name -> None

(** Build a catalog callback bound to [environment] and [transaction] so that
    [Translate] sees the real fixture schemas. Used by the pipeline-integration
    helpers below and any other test that wants the catalog wired up. *)
let make_catalog environment transaction table_name =
  Storage.Catalog.get environment transaction ~table_name

(** [with_query_result query check_rows] runs [query] through the full parse /
    lower / translate / eval pipeline against the standard fixture and calls
    [check_rows] with the resulting list of rows. The temp directory, LMDB
    environment, fixture population, and read transaction are all set up and
    torn down around the call. *)
let with_query_result query check_rows =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical
        (expect_relation (fun relation ->
             check_rows (List.of_seq relation.value))))

(** [with_query_kind query check_kind] runs [query] through the full parse /
    lower / translate / eval pipeline against the standard fixture and calls
    [check_kind] with the resulting [Relation.kind] from the
    [Term.Relation_kind] arm. Fails the running test if [Eval] hands back a
    relation value instead. Mirrors {!with_query_result} for queries that yield
    a kind rather than rows — currently the [type] operator. *)
let with_query_kind query check_kind =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical (function
        | Term.Relation_kind kind -> check_kind kind
        | Term.Relation_value _ | Term.Scalar_value _ | Term.Scalar_kind _
        | Term.Row_value _ | Term.Row_kind _ | Term.Catalog_value _
        | Term.Catalog_kind _ ->
            Alcotest.failf
              "expected %S to yield a relation kind but got a different term \
               arm"
              query))

(** [with_query_scalar_value query check_value] runs [query] through the full
    parse / lower / translate / eval pipeline and calls [check_value] with the
    {!Scalar.value} from the [Term.Scalar_value] arm. Fails the running test if
    [Eval] hands back any other arm. Mirrors {!with_query_result} for queries
    whose pipeline source is a scalar literal. *)
let with_query_scalar_value query check_value =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical (function
        | Term.Scalar_value value -> check_value value
        | Term.Scalar_kind _ | Term.Row_value _ | Term.Row_kind _
        | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
        | Term.Catalog_kind _ ->
            Alcotest.failf
              "expected %S to yield a scalar value but got a different term arm"
              query))

(** [with_query_scalar_kind query check_kind] runs [query] through the full
    parse / lower / translate / eval pipeline and calls [check_kind] with the
    {!Scalar.kind} from the [Term.Scalar_kind] arm. Fails the running test if
    [Eval] hands back any other arm. Mirrors {!with_query_kind} for queries
    whose [| type] step sits over a scalar source. *)
let with_query_scalar_kind query check_kind =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical (function
        | Term.Scalar_kind kind -> check_kind kind
        | Term.Scalar_value _ | Term.Row_value _ | Term.Row_kind _
        | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
        | Term.Catalog_kind _ ->
            Alcotest.failf
              "expected %S to yield a scalar kind but got a different term arm"
              query))

(** [with_query_row_value query check_row] runs [query] through the full parse /
    lower / translate / eval pipeline and calls [check_row] with the {!Row.t}
    from the [Term.Row_value] arm. Fails the running test if [Eval] hands back
    any other arm. Mirrors {!with_query_result} for queries whose pipeline
    source is a row literal. *)
let with_query_row_value query check_row =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical (function
        | Term.Row_value row -> check_row row
        | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_kind _
        | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
        | Term.Catalog_kind _ ->
            Alcotest.failf
              "expected %S to yield a row value but got a different term arm"
              query))

(** [with_query_row_kind query check_kind] runs [query] through the full parse /
    lower / translate / eval pipeline and calls [check_kind] with the
    {!Row.kind} from the [Term.Row_kind] arm. Fails the running test if [Eval]
    hands back any other arm. Mirrors {!with_query_kind} for queries whose
    [| type] step sits over a row source. *)
let with_query_row_kind query check_kind =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Execution.Eval.eval environment transaction physical (function
        | Term.Row_kind kind -> check_kind kind
        | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_value _
        | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
        | Term.Catalog_kind _ ->
            Alcotest.failf
              "expected %S to yield a row kind but got a different term arm"
              query))

(** [with_query_failure ~label ~expected query] runs [query] through the same
    pipeline as {!with_query_result} but asserts that [Eval.eval] raises
    [expected]. [label] is the description shown in test output. *)
let with_query_failure ~label ~expected query =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let ast =
        match Surface_ra.Parser.parse query with
        | Ok plan -> plan
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Surface_ra.Lower.lower ast in
      let catalog = make_catalog environment transaction in
      let physical = Plan.Translate.translate ~catalog logical in
      Alcotest.check_raises label expected (fun () ->
          Execution.Eval.eval environment transaction physical (fun _term -> ())))

(** [evaluate_against_fixture plan] populates the standard fixture and evaluates
    [plan] inside a read transaction, returning the resulting kind and rows. The
    temp directory, LMDB environment, fixture population, and read transaction
    are all set up and torn down around the call. *)
let evaluate_against_fixture plan =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Execution.Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             (relation.kind, List.of_seq relation.value))))

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
