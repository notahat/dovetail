(** End-to-end tests for [Eval.eval] on [Physical.Drop_table].

    Drop_table is a leaf write operator: it takes no relational input, removes a
    table from the catalog and its storage subDB inside the active write
    transaction, and yields a one-row [(dropped : string)] relation reporting
    the dropped table's name. These tests construct the plan by hand and run it
    against a live LMDB environment. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Storage = Dovetail_storage

let test_drop_table_removes_table_and_reports_dropped () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t = Drop_table { table_name = "orders" } in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction plan
        (expect_relation (fun (relation : [ `Bag ] Relation.t) ->
             Alcotest.(check (list string))
               "result kind has one (dropped : string) column" [ "dropped" ]
               (List.map
                  (fun (field : Row.field) -> field.name)
                  relation.kind.row_kind);
             Alcotest.(check row_list_testable)
               "result is a single (dropped = \"orders\") row"
               [ [| Scalar.String "orders" |] ]
               (List.of_seq relation.value))));
  (* In a fresh read transaction, the catalog no longer knows about
     [orders] -- so the drop committed rather than just being visible to
     the writer. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option pass))
        "orders has no catalog entry after drop" None
        (Storage.Catalog.get environment transaction ~table_name:"orders"))

let test_drop_table_unknown_table_raises () =
  with_fixture_environment @@ fun environment ->
  let plan : Plan.Physical.t = Drop_table { table_name = "ghost" } in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Alcotest.check_raises "no such table"
        (Failure "Eval: drop table \"ghost\": no such table") (fun () ->
          Eval.eval environment transaction plan (fun _ -> ())))

let () =
  Alcotest.run "eval drop_table"
    [
      ( "drop_table",
        [
          Alcotest.test_case
            "writes through: removes catalog entry and reports dropped name"
            `Quick test_drop_table_removes_table_and_reports_dropped;
          Alcotest.test_case "raises a user-facing error on an unknown table"
            `Quick test_drop_table_unknown_table_raises;
        ] );
    ]
