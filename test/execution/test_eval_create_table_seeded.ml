(** End-to-end tests for [Eval.eval] on [Physical.Create_table_seeded].

    Create_table_seeded derives the target kind from its source's row kind, runs
    the qualifier-rejection check, stamps [Some table_name] onto every field,
    validates the structural rules (no-PK is the user-visible one), rejects a
    colliding existing table, then provisions storage and catalog and writes the
    source rows -- all in one write transaction. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* A typed single-row relation literal: two fields with a single-column
   primary key, no qualifier. Suitable as the source for a successful
   seeded create. *)
let widgets_literal_source : Plan.Physical.t =
  Relation_literal
    {
      kind =
        {
          row_kind =
            [
              { name = "id"; kind = Int64; qualifier = None };
              { name = "name"; kind = String; qualifier = None };
            ];
          refinements = [ Primary_key [ "id" ] ];
        };
      rows = [ [ Scalar.Int64 1L; Scalar.String "alice" ] ];
    }

let test_seeded_from_literal_creates_table_and_writes_rows () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t =
    Create_table_seeded
      { table_name = "widgets"; source = widgets_literal_source }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction plan
        (expect_relation (fun (relation : [ `Bag ] Relation.t) ->
             Alcotest.(check row_list_testable)
               "result is a single (created = \"widgets\") row"
               [ [| Scalar.String "widgets" |] ]
               (List.of_seq relation.value))));
  (* Catalog entry exists with the stamped qualifier; the seeded row is
     persisted under a fresh read transaction. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      (match
         Storage.Catalog.get environment transaction ~table_name:"widgets"
       with
      | None -> Alcotest.fail "widgets has no catalog entry after create"
      | Some kind ->
          let qualifiers =
            List.map (fun (field : Row.field) -> field.qualifier) kind.row_kind
          in
          Alcotest.(check (list (option string)))
            "every stored field is qualified by the new table name"
            [ Some "widgets"; Some "widgets" ]
            qualifiers);
      Eval.eval environment transaction
        (Plan.Physical.FullScan { table = "widgets" })
        (expect_relation (fun relation ->
             Alcotest.(check row_list_testable)
               "the seeded row is present"
               [ [| Scalar.Int64 1L; Scalar.String "alice" |] ]
               (List.of_seq relation.value))))

let test_seeded_from_unqualified_scan_creates_table_and_writes_rows () =
  (* The fixture's [users] table qualifies every field with [Some "users"],
     so a bare scan piped to create_table would fail the qualifier check.
     [Unqualify] strips them; [Create_table_seeded] then derives a fresh,
     unqualified source kind and stamps the new table's name onto it. *)
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t =
    Create_table_seeded
      {
        table_name = "users_copy";
        source = Unqualify { input = FullScan { table = "users" } };
      }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction plan
        (expect_relation (fun (relation : [ `Bag ] Relation.t) ->
             Alcotest.(check row_list_testable)
               "result is a single (created = \"users_copy\") row"
               [ [| Scalar.String "users_copy" |] ]
               (List.of_seq relation.value))));
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Plan.Physical.FullScan { table = "users_copy" })
        (expect_relation (fun relation ->
             Alcotest.(check int)
               "all five fixture user rows were copied" 5
               (Seq.length relation.value))))

let test_seeded_rejects_qualified_source () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t =
    Create_table_seeded
      { table_name = "users_copy"; source = FullScan { table = "users" } }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "qualified source"
        (Failure
           "Eval: create table \"users_copy\": source has qualified field(s) \
            \"users.id\", \"users.name\", \"users.email\", \"users.active\"; \
            pipe through unqualify to drop qualifiers") (fun () ->
          Eval.eval environment transaction plan (fun _ -> ())))

let test_seeded_rejects_source_without_primary_key () =
  with_fixture_environment @@ fun environment ->
  let source : Plan.Physical.t =
    Relation_literal
      {
        kind =
          {
            row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
            refinements = [];
          };
        rows = [];
      }
  in
  let plan : Plan.Physical.t =
    Create_table_seeded { table_name = "widgets"; source }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "no primary key in derived source kind"
        (Failure "Eval: create table \"widgets\": primary key is empty")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let test_seeded_rejects_existing_table () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t =
    Create_table_seeded
      { table_name = "orders"; source = widgets_literal_source }
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "orders is in the fixture"
        (Failure "Eval: create table \"orders\": table already exists")
        (fun () -> Eval.eval environment transaction plan (fun _ -> ())))

let () =
  Alcotest.run "eval create_table_seeded"
    [
      ( "create_table_seeded",
        [
          Alcotest.test_case
            "writes through from a Relation_literal source and seeds the rows"
            `Quick test_seeded_from_literal_creates_table_and_writes_rows;
          Alcotest.test_case
            "writes through from an unqualified Scan source and copies its rows"
            `Quick
            test_seeded_from_unqualified_scan_creates_table_and_writes_rows;
          Alcotest.test_case
            "rejects a qualified source and points at unqualify" `Quick
            test_seeded_rejects_qualified_source;
          Alcotest.test_case "rejects a source whose derived kind has no PK"
            `Quick test_seeded_rejects_source_without_primary_key;
          Alcotest.test_case "rejects an already-existing target table" `Quick
            test_seeded_rejects_existing_table;
        ] );
    ]
