(** End-to-end tests for [Eval.eval] on [Physical.Insert].

    Insert is a regular operator in [Physical.t] post-collapse, so it runs
    through the same [Eval.eval] entry as every other operator. These tests
    construct the Insert plan by hand and call [Eval.eval] inside a write
    transaction. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a [Relation.kind] mirroring the source row's columns: each field's
   scalar kind comes from the value's runtime constructor, matching what
   Lower produces for a typed relation literal. *)
let kind_from_pairs pairs : Relation.kind =
  {
    row_kind =
      List.map
        (fun (name, value) : Row.field ->
          { name; kind = Scalar.kind_of value; qualifier = None })
        pairs;
    refinements = [];
  }

(* Build a [Physical.Insert] whose source is a single-row [Relation_literal]
   with the same target schema as [insert_mutation], but with [qualifier]
   stamped onto each source field. Lets a test exercise the sink's
   qualified-input rejection without going through a join. *)
let insert_mutation_qualified ~table ~qualifier ~pairs : Plan.Physical.t =
  let kind : Relation.kind =
    {
      row_kind =
        List.map
          (fun (name, value) : Row.field ->
            { name; kind = Scalar.kind_of value; qualifier = Some qualifier })
          pairs;
      refinements = [];
    }
  in
  let values = List.map snd pairs in
  Insert { table; source = Relation_literal { kind; rows = [ values ] } }

(* Build a [Physical.Insert] sourced from a multi-row literal in target
   schema order, so the count-reporting tests can vary the source size.
   [column_kinds] declares the literal's kind; every row in [rows] has the
   same arity and per-position kinds. *)
let insert_mutation_multi ~table ~column_kinds ~rows : Plan.Physical.t =
  let kind : Relation.kind =
    {
      row_kind =
        List.map
          (fun (name, scalar_kind) : Row.field ->
            { name; kind = scalar_kind; qualifier = None })
          column_kinds;
      refinements = [];
    }
  in
  Insert { table; source = Relation_literal { kind; rows } }

(* Build a [Physical.Insert] whose source is a single-row [Relation_literal]
   with the given column/value pairs. The pairs are in target schema order;
   this keeps the tests focused on the sink itself and not on column
   reordering (Translate-level permutation validation lets the sink trust
   its input). *)
let insert_mutation ~table ~pairs : Plan.Physical.t =
  let kind = kind_from_pairs pairs in
  let values = List.map snd pairs in
  Insert { table; source = Relation_literal { kind; rows = [ values ] } }

let test_insert_writes_row_and_reports_one_affected () =
  with_fixture_environment @@ fun environment ->
  let mutation =
    insert_mutation ~table:"orders"
      ~pairs:
        [
          ("id", Scalar.Int64 9L);
          ("user_id", Scalar.Int64 1L);
          ("description", Scalar.String "Pretzel");
          ("amount", Scalar.Int64 9L);
        ]
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction mutation
        (expect_relation (fun (relation : [ `Bag ] Relation.t) ->
             Alcotest.(check (list string))
               "result kind has one insert_count column" [ "insert_count" ]
               (List.map
                  (fun (field : Row.field) -> field.name)
                  relation.kind.row_kind);
             Alcotest.(check row_list_testable)
               "result has a single (insert_count = 1) row"
               [ [| Scalar.Int64 1L |] ]
               (List.of_seq relation.value))));
  (* The row should now be present in a fresh read transaction, so we know
     the write committed rather than just being visible to the writer. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Plan.Physical.FullScan { table = "orders" })
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             let inserted =
               List.find_opt
                 (fun (row : Row.value) -> row.(0) = Scalar.Int64 9L)
                 rows
             in
             match inserted with
             | None -> Alcotest.fail "inserted row not found in orders"
             | Some row ->
                 Alcotest.(check row_list_testable)
                   "inserted row matches"
                   [
                     [|
                       Scalar.Int64 9L;
                       Scalar.Int64 1L;
                       Scalar.String "Pretzel";
                       Scalar.Int64 9L;
                     |];
                   ]
                   [ row ])))

let test_insert_three_rows_reports_count_of_three () =
  with_fixture_environment @@ fun environment ->
  let mutation =
    insert_mutation_multi ~table:"orders"
      ~column_kinds:
        [
          ("id", Int64);
          ("user_id", Int64);
          ("description", String);
          ("amount", Int64);
        ]
      ~rows:
        [
          [
            Scalar.Int64 10L;
            Scalar.Int64 1L;
            Scalar.String "A";
            Scalar.Int64 1L;
          ];
          [
            Scalar.Int64 11L;
            Scalar.Int64 1L;
            Scalar.String "B";
            Scalar.Int64 2L;
          ];
          [
            Scalar.Int64 12L;
            Scalar.Int64 1L;
            Scalar.String "C";
            Scalar.Int64 3L;
          ];
        ]
  in
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Eval.eval environment transaction mutation
        (expect_relation (fun (relation : [ `Bag ] Relation.t) ->
             Alcotest.(check row_list_testable)
               "three rows inserted yields insert_count = 3"
               [ [| Scalar.Int64 3L |] ]
               (List.of_seq relation.value))))

let test_insert_with_existing_primary_key_raises () =
  with_fixture_environment @@ fun environment ->
  let mutation =
    insert_mutation ~table:"orders"
      ~pairs:
        [
          (* Order id 1 is the first fixture row -- guaranteed collision. *)
          ("id", Scalar.Int64 1L);
          ("user_id", Scalar.Int64 1L);
          ("description", Scalar.String "Duplicate");
          ("amount", Scalar.Int64 1L);
        ]
  in
  Alcotest.check_raises "primary-key collision"
    (Failure
       "Eval: insert into \"orders\": row with primary key 1 already exists")
    (fun () ->
      Storage.Engine.with_write_transaction environment (fun transaction ->
          Eval.eval environment transaction mutation (fun _ -> ())));
  (* The transaction aborted on the raised exception, so the table should
     be unchanged. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Plan.Physical.FullScan { table = "orders" })
        (expect_relation (fun relation ->
             let rows = List.of_seq relation.value in
             Alcotest.(check row_list_testable)
               "orders unchanged after aborted insert" expected_orders_rows rows)))

let test_insert_with_qualified_source_field_is_rejected () =
  with_fixture_environment @@ fun environment ->
  let mutation =
    insert_mutation_qualified ~table:"orders" ~qualifier:"orders"
      ~pairs:
        [
          ("id", Scalar.Int64 9L);
          ("user_id", Scalar.Int64 1L);
          ("description", Scalar.String "Pretzel");
          ("amount", Scalar.Int64 9L);
        ]
  in
  Alcotest.check_raises "qualified source rejected"
    (Failure
       "Eval: insert into \"orders\": source has qualified field(s) \
        \"orders.id\", \"orders.user_id\", \"orders.description\", \
        \"orders.amount\"; pipe through unqualify to drop qualifiers")
    (fun () ->
      Storage.Engine.with_write_transaction environment (fun transaction ->
          Eval.eval environment transaction mutation (fun _ -> ())))

let () =
  Alcotest.run "eval_insert"
    [
      ( "insert sink",
        [
          Alcotest.test_case
            "writes the row and reports one affected row on success" `Quick
            test_insert_writes_row_and_reports_one_affected;
          Alcotest.test_case "three rows inserted yields insert_count = 3"
            `Quick test_insert_three_rows_reports_count_of_three;
          Alcotest.test_case
            "raises and leaves storage untouched on a primary-key collision"
            `Quick test_insert_with_existing_primary_key_raises;
          Alcotest.test_case
            "rejects a source row whose fields carry qualifiers" `Quick
            test_insert_with_qualified_source_field_is_rejected;
        ] );
    ]
