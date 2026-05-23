(** End-to-end tests for [Eval] on [Physical.RelationLiteral]. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* Build a single-row [Physical.RelationLiteral] plan and pass the materialised
   relation into [f]. Each per-attribute test below uses this so the eval
   scaffolding stays in one place and the test bodies do one assertion each. *)
let with_literal_relation f =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        RelationLiteral
          {
            columns = [ "id"; "name"; "active" ];
            rows =
              [ [ Scalar.Int64 7L; Scalar.String "Pretzel"; Scalar.Bool true ] ];
          }
      in
      Eval.eval environment transaction plan f)

let test_field_names_match_the_literals_columns () =
  with_literal_relation @@ fun relation ->
  Alcotest.(check (list string))
    "field names come from the literal's [columns]" [ "id"; "name"; "active" ]
    (List.map (fun (field : Row.field) -> field.name) relation.kind.row_kind)

let test_field_qualifiers_are_all_absent () =
  with_literal_relation @@ fun relation ->
  Alcotest.(check (list (option string)))
    "every field's qualifier is None" [ None; None; None ]
    (List.map
       (fun (field : Row.field) -> field.qualifier)
       relation.kind.row_kind)

let test_field_kinds_are_inferred_from_the_first_row () =
  with_literal_relation @@ fun relation ->
  Alcotest.(check (list string))
    "field kinds match the first row's value kinds"
    [ "Int64"; "String"; "Bool" ]
    (List.map
       (fun (field : Row.field) -> Scalar.kind_to_string field.kind)
       relation.kind.row_kind)

let test_primary_key_is_empty () =
  with_literal_relation @@ fun relation ->
  Alcotest.(check int)
    "derived relations carry no refinements" 0
    (List.length relation.kind.refinements)

let test_rows_match_the_literals_row () =
  with_literal_relation @@ fun relation ->
  let rows = List.of_seq relation.value in
  Alcotest.(check row_list_testable)
    "one row, values match the literal"
    [ [| Scalar.Int64 7L; Scalar.String "Pretzel"; Scalar.Bool true |] ]
    rows

let () =
  Alcotest.run "eval_relation_literal"
    [
      ( "relation literal",
        [
          Alcotest.test_case "field names come from the literal's columns"
            `Quick test_field_names_match_the_literals_columns;
          Alcotest.test_case "field qualifiers are all absent" `Quick
            test_field_qualifiers_are_all_absent;
          Alcotest.test_case "field kinds are inferred from the first row"
            `Quick test_field_kinds_are_inferred_from_the_first_row;
          Alcotest.test_case "primary key is empty" `Quick
            test_primary_key_is_empty;
          Alcotest.test_case "rows match the literal's row" `Quick
            test_rows_match_the_literals_row;
        ] );
    ]
