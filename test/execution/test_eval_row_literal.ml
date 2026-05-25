(** End-to-end tests for [Eval] on [Physical.Row_literal].

    A row literal at the pipeline source flows through evaluation as a
    [Term.Row_value]; [Type_op] over a row literal short-circuits before
    [Physical.kind_of] is consulted and yields a [Term.Row_kind] derived from
    the literal's field values. *)

open Dovetail_execution
open Test_helpers
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row

let expect_row_value callback : [ `Bag ] Term.t -> 'a = function
  | Term.Row_value row -> callback row
  | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_kind _
  | Term.Relation_value _ | Term.Relation_kind _ ->
      Alcotest.fail "expected a row value but got a different term arm"

let expect_row_kind callback : [ `Bag ] Term.t -> 'a = function
  | Term.Row_kind kind -> callback kind
  | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_value _
  | Term.Relation_value _ | Term.Relation_kind _ ->
      Alcotest.fail "expected a row kind but got a different term arm"

let row_testable : Row.t Alcotest.testable = Alcotest.testable Row.format ( = )

let row_kind_testable : Row.kind Alcotest.testable =
  Alcotest.testable Row.format_kind ( = )

(* The row arms don't open cursors, but [Eval.eval] still needs a
   transaction. Run inside an empty environment so the harness stays
   honest: the test would notice if the implementation started touching
   storage on a row source. *)
let with_environment_and_transaction body =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      body environment transaction)

let test_row_literal_evaluates_to_row_value () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Row_literal
      {
        fields =
          [
            (column_reference "id", Scalar.Int64 1L);
            (column_reference "name", Scalar.String "alice");
          ];
      }
  in
  let expected : Row.t =
    {
      kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      value = [| Scalar.Int64 1L; Scalar.String "alice" |];
    }
  in
  Eval.eval environment transaction plan
    (expect_row_value (fun row ->
         Alcotest.(check row_testable)
           "row literal yields a row with matching kind and values" expected row))

let test_empty_row_literal_evaluates_to_empty_row_value () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t = Row_literal { fields = [] } in
  let expected : Row.t = { kind = []; value = [||] } in
  Eval.eval environment transaction plan
    (expect_row_value (fun row ->
         Alcotest.(check row_testable)
           "empty row literal yields empty row" expected row))

let test_type_op_over_row_literal_yields_row_kind () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Type_op
      {
        input =
          Row_literal
            {
              fields =
                [
                  (column_reference "id", Scalar.Int64 1L);
                  (column_reference "name", Scalar.String "alice");
                ];
            };
      }
  in
  let expected : Row.kind =
    [
      { name = "id"; kind = Int64; qualifier = None };
      { name = "name"; kind = String; qualifier = None };
    ]
  in
  Eval.eval environment transaction plan
    (expect_row_kind (fun kind ->
         Alcotest.(check row_kind_testable)
           "type of a row literal is the matching row kind" expected kind))

let test_type_op_over_empty_row_literal_yields_empty_row_kind () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Type_op { input = Row_literal { fields = [] } }
  in
  Eval.eval environment transaction plan
    (expect_row_kind (fun kind ->
         Alcotest.(check row_kind_testable)
           "type of empty row literal is empty" [] kind))

let () =
  Alcotest.run "eval_row_literal"
    [
      ( "row literal",
        [
          Alcotest.test_case "row literal evaluates to Term.Row_value" `Quick
            test_row_literal_evaluates_to_row_value;
          Alcotest.test_case
            "empty row literal evaluates to empty Term.Row_value" `Quick
            test_empty_row_literal_evaluates_to_empty_row_value;
        ] );
      ( "type op",
        [
          Alcotest.test_case "Type_op over row literal yields Term.Row_kind"
            `Quick test_type_op_over_row_literal_yields_row_kind;
          Alcotest.test_case
            "Type_op over empty row literal yields empty Term.Row_kind" `Quick
            test_type_op_over_empty_row_literal_yields_empty_row_kind;
        ] );
    ]
