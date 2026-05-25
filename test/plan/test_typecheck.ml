(** Tests for [Typecheck].

    The pass walks a [Logical.t] against a snapshotted catalog and accumulates
    structured errors. Tests assert both the structured variant and its rendered
    form for each error class. *)

open Dovetail_plan
module Catalog = Dovetail_core.Catalog
module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

let logical_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical>")) ( = )

let error_list_testable =
  Alcotest.testable
    (Fmt.of_to_string (fun errors ->
         String.concat " | " (List.map Typecheck.render errors)))
    ( = )

(* Three columns, all qualified to "orders". Used as a stand-in target
   schema for the Insert tests below. *)
let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* Build an [Insert] of a [Relation_literal] whose [kind] is derived from the
   supplied [pairs] (one per column). Values are placeholders -- this slice
   only cares about column-name agreement. *)
let insert_literal ~table ~pairs : Logical.t =
  let row_kind =
    List.map
      (fun (name, value) : Row.field ->
        { name; kind = Scalar.kind_of value; qualifier = None })
      pairs
  in
  let row = List.map snd pairs in
  Insert
    {
      table;
      source =
        Relation_literal
          { kind = { row_kind; refinements = [] }; rows = [ row ] };
    }

let orders_catalog : Catalog.kind =
  { relation_kinds = [ ("orders", orders_kind) ] }

let test_empty_pass_returns_input_unchanged () =
  let catalog : Catalog.kind = { relation_kinds = [] } in
  let plan : Logical.t = Scan { table = "users" } in
  match Typecheck.typecheck ~catalog plan with
  | Ok result -> Alcotest.(check logical_testable) "plan unchanged" plan result
  | Error _ -> Alcotest.fail "expected Ok with no errors"

let test_insert_with_missing_columns_reports_structured_error () =
  let plan =
    insert_literal ~table:"orders" ~pairs:[ ("id", Scalar.Int64 9L) ]
    (* description and amount missing. *)
  in
  let expected : Typecheck.error list =
    [
      Insert_column_mismatch
        {
          table_name = "orders";
          missing = [ "description"; "amount" ];
          extra = [];
        };
    ]
  in
  match Typecheck.typecheck ~catalog:orders_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Insert_column_mismatch error"
  | Error errors ->
      Alcotest.(check error_list_testable) "structured mismatch" expected errors

let test_insert_with_missing_columns_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Insert_column_mismatch
      {
        table_name = "orders";
        missing = [ "description"; "amount" ];
        extra = [];
      }
  in
  Alcotest.(check string)
    "rendered missing-columns error"
    "Insert: into \"orders\": missing column(s): description, amount"
    (Typecheck.render error)

let test_insert_with_unknown_columns_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Insert_column_mismatch
      { table_name = "orders"; missing = []; extra = [ "colour" ] }
  in
  Alcotest.(check string)
    "rendered unknown-columns error"
    "Insert: into \"orders\": unknown column(s): colour"
    (Typecheck.render error)

let test_insert_with_both_missing_and_unknown_renders_both_halves () =
  let error : Typecheck.error =
    Insert_column_mismatch
      { table_name = "orders"; missing = [ "amount" ]; extra = [ "colour" ] }
  in
  Alcotest.(check string)
    "rendered combined error"
    "Insert: into \"orders\": missing column(s): amount; unknown column(s): \
     colour"
    (Typecheck.render error)

let test_insert_into_unknown_table_reports_no_typecheck_error () =
  (* Unknown-table reporting is not yet a Typecheck concern -- Translate still
     handles it. The walker should pass through silently rather than
     fabricate a column-mismatch error. *)
  let plan =
    insert_literal ~table:"widgets" ~pairs:[ ("id", Scalar.Int64 1L) ]
  in
  match Typecheck.typecheck ~catalog:orders_catalog plan with
  | Ok _ -> ()
  | Error errors ->
      Alcotest.failf "expected Ok; got %d error(s)" (List.length errors)

let () =
  Alcotest.run "typecheck"
    [
      ( "no-op pass",
        [
          Alcotest.test_case "returns input unchanged" `Quick
            test_empty_pass_returns_input_unchanged;
        ] );
      ( "insert column mismatch",
        [
          Alcotest.test_case "missing columns produce a structured error" `Quick
            test_insert_with_missing_columns_reports_structured_error;
          Alcotest.test_case "missing columns render with Insert prefix" `Quick
            test_insert_with_missing_columns_renders_with_insert_prefix;
          Alcotest.test_case "unknown columns render with Insert prefix" `Quick
            test_insert_with_unknown_columns_renders_with_insert_prefix;
          Alcotest.test_case "missing and unknown render together" `Quick
            test_insert_with_both_missing_and_unknown_renders_both_halves;
          Alcotest.test_case "unknown target table is not a typecheck error yet"
            `Quick test_insert_into_unknown_table_reports_no_typecheck_error;
        ] );
    ]
