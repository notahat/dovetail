(** End-to-end tests for [Eval.eval_mutation] on [Physical.Insert].

    Slice 11 step 2a introduces the insert sink behind a dedicated entry point;
    Translate and the REPL still go only through the read-only [Eval.eval], so
    there is no parser path that reaches a [Physical.mutation] yet. Tests
    construct the mutation by hand and call [Eval.eval_mutation] inside a write
    transaction. *)

open Dovetail
open Test_helpers

(* Build a [Physical.Insert] whose source is a single-row [RelationLiteral]
   with the given column/value pairs. The pairs are in target schema order;
   this keeps the tests focused on the sink itself and not on column
   reordering (Step 3 introduces Translate-level permutation validation
   that lets the sink trust its input). *)
let insert_mutation ~table ~pairs : Physical.mutation =
  let columns = List.map fst pairs in
  let values = List.map snd pairs in
  Insert { table; source = RelationLiteral { columns; rows = [ values ] } }

let test_insert_writes_row_and_reports_one_affected () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  let mutation =
    insert_mutation ~table:"orders"
      ~pairs:
        [
          ("id", Value.Int64 9L);
          ("user_id", Value.Int64 1L);
          ("description", Value.String "Pretzel");
          ("amount", Value.Int64 9L);
        ]
  in
  Storage.with_write_transaction environment (fun transaction ->
      let affected_rows = Eval.eval_mutation environment transaction mutation in
      Alcotest.(check int) "one row affected" 1 affected_rows);
  (* The row should now be present in a fresh read transaction, so we know
     the write committed rather than just being visible to the writer. *)
  Storage.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Physical.FullScan { table = "orders" })
        (fun relation ->
          let rows = List.of_seq relation.tuples in
          let inserted =
            List.find_opt
              (fun (tuple : Schema.tuple) -> tuple.(0) = Value.Int64 9L)
              rows
          in
          match inserted with
          | None -> Alcotest.fail "inserted row not found in orders"
          | Some tuple ->
              Alcotest.(check tuple_list_testable)
                "inserted tuple matches"
                [
                  [|
                    Value.Int64 9L;
                    Value.Int64 1L;
                    Value.String "Pretzel";
                    Value.Int64 9L;
                  |];
                ]
                [ tuple ]))

let test_insert_with_existing_primary_key_raises () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  let mutation =
    insert_mutation ~table:"orders"
      ~pairs:
        [
          (* Order id 1 is the first fixture row -- guaranteed collision. *)
          ("id", Value.Int64 1L);
          ("user_id", Value.Int64 1L);
          ("description", Value.String "Duplicate");
          ("amount", Value.Int64 1L);
        ]
  in
  Alcotest.check_raises "primary-key collision"
    (Failure
       "Eval: insert into \"orders\" failed: row with primary key 1 already \
        exists") (fun () ->
      Storage.with_write_transaction environment (fun transaction ->
          ignore (Eval.eval_mutation environment transaction mutation)));
  (* The transaction aborted on the raised exception, so the table should
     be unchanged. *)
  Storage.with_read_transaction environment (fun transaction ->
      Eval.eval environment transaction
        (Physical.FullScan { table = "orders" })
        (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "orders unchanged after aborted insert" expected_orders_rows rows))

let () =
  Alcotest.run "eval_insert"
    [
      ( "insert sink",
        [
          Alcotest.test_case
            "writes the row and reports one affected row on success" `Quick
            test_insert_writes_row_and_reports_one_affected;
          Alcotest.test_case
            "raises and leaves storage untouched on a primary-key collision"
            `Quick test_insert_with_existing_primary_key_raises;
        ] );
    ]
