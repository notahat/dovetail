(** End-to-end tests for [Eval] on [Physical.Type_op].

    [Type_op] is the only operator whose evaluation result is a
    [Term.Relation_kind] rather than a [Term.Relation_value]. The tests here
    exercise the kind-arm path: a [Type_op] over the [users] fixture yields the
    relation kind that [Storage.Catalog] holds for [users], without opening any
    cursors. *)

open Dovetail_execution
open Test_helpers
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(** [expect_relation_kind callback term] applies [callback] to the kind inside
    [term], failing the running test with [Alcotest.fail] if [term] is the
    relation-value arm instead. *)
let expect_relation_kind callback : [ `Bag ] Term.t -> 'a = function
  | Term.Relation_kind kind -> callback kind
  | Term.Relation_value _ | Term.Scalar_value _ | Term.Scalar_kind _
  | Term.Row_value _ | Term.Row_kind _ | Term.Catalog_value _
  | Term.Catalog_kind _ ->
      Alcotest.fail "expected a relation kind but got a different term arm"

let kind_testable : Relation.kind Alcotest.testable =
  Alcotest.testable Relation.format_kind ( = )

let test_type_op_over_full_scan_yields_users_catalog_kind () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let expected_kind =
        match
          Storage.Catalog.get environment transaction ~table_name:"users"
        with
        | Some kind -> kind
        | None -> Alcotest.fail "fixture did not populate the users catalog"
      in
      let plan : Plan.Physical.t =
        Type_op { input = FullScan { table = "users" } }
      in
      Eval.eval environment transaction plan
        (expect_relation_kind (fun kind ->
             Alcotest.(check kind_testable)
               "Type_op over FullScan yields the users catalog kind"
               expected_kind kind)))

(* Dispatch on the [Term.Catalog_kind] arm or fail with a description of the
   wrong arm. *)
let expect_catalog_kind callback : [ `Bag ] Term.t -> 'a = function
  | Term.Catalog_kind kind -> callback kind
  | Term.Catalog_value _ | Term.Relation_value _ | Term.Relation_kind _
  | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_value _
  | Term.Row_kind _ ->
      Alcotest.fail "expected a catalog kind but got a different term arm"

let test_type_op_over_catalog_source_yields_catalog_kind () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t = Type_op { input = Catalog_source } in
      Eval.eval environment transaction plan
        (expect_catalog_kind (fun kind ->
             Alcotest.(check (list string))
               "catalog kind lists the fixture's table names in cursor order"
               [ "orders"; "users" ]
               (List.map fst kind.relation_kinds))))

let test_type_op_over_missing_table_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        Type_op { input = FullScan { table = "ghost" } }
      in
      Alcotest.check_raises "missing table inside Type_op"
        (Failure "Physical.kind_of: unknown table \"ghost\"") (fun () ->
          Eval.eval environment transaction plan (fun _term -> ())))

let () =
  Alcotest.run "eval_type_op"
    [
      ( "type op",
        [
          Alcotest.test_case
            "yields the input's relation kind without opening cursors" `Quick
            test_type_op_over_full_scan_yields_users_catalog_kind;
          Alcotest.test_case "raises when the input references an unknown table"
            `Quick test_type_op_over_missing_table_raises;
          Alcotest.test_case
            "over a Catalog_source yields a Catalog_kind without opening row \
             cursors"
            `Quick test_type_op_over_catalog_source_yields_catalog_kind;
        ] );
    ]
