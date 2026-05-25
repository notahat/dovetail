(** End-to-end tests for [Eval.eval] on [Physical.Create_table_empty].

    Create_table_empty is a leaf write operator: it carries a resolved
    [Relation.kind], runs the structural and catalog checks inside the active
    write transaction, then provisions the storage subDB and catalog entry. The
    result is a one-row [(created : string)] relation carrying the new table's
    name. These tests construct the plan by hand and run it against a live LMDB
    environment, mirroring the pattern in [test_eval_drop_table.ml]. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* A well-formed [Relation.kind] mirroring the kind a successful
   [<type-expr> | create table widgets] would carry: two fields with a
   single-column primary key, no qualifier as written by the user. The
   evaluator stamps [Some table_name] onto every field before writing
   the catalog entry, so the catalog kind read back here has the
   qualifier set even though the input carried [None]. *)
let widgets_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let create_widgets : Plan.Physical.t =
  Create_table_empty { table_name = "widgets"; kind = widgets_kind }

let test_create_table_empty_writes_catalog_and_reports_created () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction create_widgets
        (expect_relation (fun (relation : [ `Set | `Bag ] Relation.t) ->
             Alcotest.(check (list string))
               "result kind has one (created : string) column" [ "created" ]
               (List.map
                  (fun (field : Row.field) -> field.name)
                  relation.kind.row_kind);
             Alcotest.(check row_list_testable)
               "result is a single (created = \"widgets\") row"
               [ [| Scalar.String "widgets" |] ]
               (List.of_seq relation.value))));
  (* In a fresh read transaction, the catalog reflects the new table --
     so the create committed rather than being writer-only. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      match
        Storage.Catalog.get environment transaction ~table_name:"widgets"
      with
      | None -> Alcotest.fail "widgets has no catalog entry after create"
      | Some kind ->
          Alcotest.(check int)
            "stored kind has two columns" 2
            (List.length kind.row_kind))

let test_create_table_empty_table_already_exists_raises () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "orders"; kind = widgets_kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "orders already in the fixture"
        (Failure "Eval: create table \"orders\": table already exists")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let test_create_table_empty_rejects_empty_column_list () =
  with_fixture_environment @@ fun environment ->
  let kind : Relation.kind =
    { row_kind = []; refinements = [ Primary_key [ "id" ] ] }
  in
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "widgets"; kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "empty fields"
        (Failure "Eval: create table \"widgets\": column list is empty")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let test_create_table_empty_rejects_duplicate_column_name () =
  with_fixture_environment @@ fun environment ->
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "id"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "widgets"; kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "duplicate column name"
        (Failure "Eval: create table \"widgets\": column \"id\" appears twice")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let test_create_table_empty_rejects_missing_primary_key () =
  with_fixture_environment @@ fun environment ->
  let kind : Relation.kind =
    {
      row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
      refinements = [];
    }
  in
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "widgets"; kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "no primary key"
        (Failure "Eval: create table \"widgets\": primary key is empty")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let test_create_table_empty_rejects_primary_key_column_not_in_fields () =
  with_fixture_environment @@ fun environment ->
  let kind : Relation.kind =
    {
      row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
      refinements = [ Primary_key [ "missing" ] ];
    }
  in
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "widgets"; kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "PK column not in field list"
        (Failure
           "Eval: create table \"widgets\": primary key column \"missing\" not \
            in column list") (fun () ->
          Eval.eval environment transaction plan (fun _ -> ())))

let test_create_table_empty_rejects_duplicate_primary_key_column () =
  with_fixture_environment @@ fun environment ->
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "id"; "id" ] ];
    }
  in
  let plan : Plan.Physical.t =
    Create_table_empty { table_name = "widgets"; kind }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "duplicate PK column"
        (Failure
           "Eval: create table \"widgets\": primary key column \"id\" appears \
            twice") (fun () ->
          Eval.eval environment transaction plan (fun _ -> ())))

let () =
  Alcotest.run "eval create_table_empty"
    [
      ( "create_table_empty",
        [
          Alcotest.test_case
            "writes through: registers catalog and provisions storage" `Quick
            test_create_table_empty_writes_catalog_and_reports_created;
          Alcotest.test_case "raises when the table already exists" `Quick
            test_create_table_empty_table_already_exists_raises;
          Alcotest.test_case "rejects an empty column list" `Quick
            test_create_table_empty_rejects_empty_column_list;
          Alcotest.test_case "rejects a duplicate column name" `Quick
            test_create_table_empty_rejects_duplicate_column_name;
          Alcotest.test_case "rejects a missing primary key" `Quick
            test_create_table_empty_rejects_missing_primary_key;
          Alcotest.test_case
            "rejects a primary key column not in the field list" `Quick
            test_create_table_empty_rejects_primary_key_column_not_in_fields;
          Alcotest.test_case "rejects a duplicate primary key column" `Quick
            test_create_table_empty_rejects_duplicate_primary_key_column;
        ] );
    ]
