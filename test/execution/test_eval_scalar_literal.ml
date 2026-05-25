(** End-to-end tests for [Eval] on [Physical.Scalar_literal].

    A scalar literal at the pipeline source flows through evaluation as a
    [Term.Scalar_value]; [Type_op] over a scalar literal short-circuits before
    [Physical.kind_of] is consulted and yields a [Term.Scalar_kind] derived from
    the value. *)

open Dovetail_execution
open Test_helpers
module Plan = Dovetail_plan
module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar

(* Extract a scalar value or fail the running test with a description of the
   wrong arm. *)
let expect_scalar_value callback : [ `Bag ] Term.t -> 'a = function
  | Term.Scalar_value value -> callback value
  | Term.Scalar_kind _ | Term.Row_value _ | Term.Row_kind _
  | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
  | Term.Catalog_kind _ ->
      Alcotest.fail "expected a scalar value but got a different term arm"

let expect_scalar_kind callback : [ `Bag ] Term.t -> 'a = function
  | Term.Scalar_kind kind -> callback kind
  | Term.Scalar_value _ | Term.Row_value _ | Term.Row_kind _
  | Term.Relation_value _ | Term.Relation_kind _ | Term.Catalog_value _
  | Term.Catalog_kind _ ->
      Alcotest.fail "expected a scalar kind but got a different term arm"

let scalar_value_testable : Scalar.value Alcotest.testable =
  Alcotest.testable Scalar.format ( = )

let scalar_kind_testable : Scalar.kind Alcotest.testable =
  Alcotest.testable Scalar.format_kind ( = )

(* The scalar arms don't open cursors, but [Eval.eval] still needs a
   transaction. Run inside an empty environment so the harness stays
   honest: the test would notice if the implementation started touching
   storage on a scalar source. *)
let with_environment_and_transaction body =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      body environment transaction)

let test_int64_literal_evaluates_to_scalar_value () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t = Scalar_literal (Scalar.Int64 42L) in
  Eval.eval environment transaction plan
    (expect_scalar_value (fun value ->
         Alcotest.(check scalar_value_testable)
           "Int64 literal yields the same value" (Scalar.Int64 42L) value))

let test_string_literal_evaluates_to_scalar_value () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t = Scalar_literal (Scalar.String "hello") in
  Eval.eval environment transaction plan
    (expect_scalar_value (fun value ->
         Alcotest.(check scalar_value_testable)
           "String literal yields the same value" (Scalar.String "hello") value))

let test_bool_literal_evaluates_to_scalar_value () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t = Scalar_literal (Scalar.Bool true) in
  Eval.eval environment transaction plan
    (expect_scalar_value (fun value ->
         Alcotest.(check scalar_value_testable)
           "Bool literal yields the same value" (Scalar.Bool true) value))

let test_type_op_over_scalar_literal_yields_scalar_kind () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Type_op { input = Scalar_literal (Scalar.Int64 42L) }
  in
  Eval.eval environment transaction plan
    (expect_scalar_kind (fun kind ->
         Alcotest.(check scalar_kind_testable)
           "type of an Int64 literal is Int64" Scalar.Int64 kind))

let test_type_op_over_string_literal_yields_string_kind () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Type_op { input = Scalar_literal (Scalar.String "hi") }
  in
  Eval.eval environment transaction plan
    (expect_scalar_kind (fun kind ->
         Alcotest.(check scalar_kind_testable)
           "type of a String literal is String" Scalar.String kind))

let test_type_op_over_bool_literal_yields_bool_kind () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Type_op { input = Scalar_literal (Scalar.Bool false) }
  in
  Eval.eval environment transaction plan
    (expect_scalar_kind (fun kind ->
         Alcotest.(check scalar_kind_testable)
           "type of a Bool literal is Bool" Scalar.Bool kind))

let () =
  Alcotest.run "eval_scalar_literal"
    [
      ( "scalar literal",
        [
          Alcotest.test_case "Int64 literal evaluates to Term.Scalar_value"
            `Quick test_int64_literal_evaluates_to_scalar_value;
          Alcotest.test_case "String literal evaluates to Term.Scalar_value"
            `Quick test_string_literal_evaluates_to_scalar_value;
          Alcotest.test_case "Bool literal evaluates to Term.Scalar_value"
            `Quick test_bool_literal_evaluates_to_scalar_value;
        ] );
      ( "type op",
        [
          Alcotest.test_case
            "Type_op over Int64 literal yields Scalar_kind Int64" `Quick
            test_type_op_over_scalar_literal_yields_scalar_kind;
          Alcotest.test_case
            "Type_op over String literal yields Scalar_kind String" `Quick
            test_type_op_over_string_literal_yields_string_kind;
          Alcotest.test_case "Type_op over Bool literal yields Scalar_kind Bool"
            `Quick test_type_op_over_bool_literal_yields_bool_kind;
        ] );
    ]
