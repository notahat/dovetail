(** End-to-end tests for [Eval] on [Physical.Relation_literal]. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Plan = Dovetail_plan
module Storage = Dovetail_storage

(* The kind every test below builds the literal with. Declared up front; Eval
   threads it through to the materialised relation unchanged. *)
let literal_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
        { name = "active"; kind = Bool; qualifier = None };
      ];
    refinements = [];
  }

(* Build a single-row [Physical.Relation_literal] plan and pass the
   materialised relation into [f]. Each per-attribute test below uses this so
   the eval scaffolding stays in one place and the test bodies do one
   assertion each. *)
let with_literal_relation f =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        Relation_literal
          {
            kind = literal_kind;
            rows =
              [ [ Scalar.Int64 7L; Scalar.String "Pretzel"; Scalar.Bool true ] ];
          }
      in
      Eval.eval environment transaction plan (expect_relation f))

let test_kind_is_the_declared_kind () =
  with_literal_relation @@ fun relation ->
  Alcotest.(check (list string))
    "field names come from the declared kind" [ "id"; "name"; "active" ]
    (List.map (fun (field : Row.field) -> field.name) relation.kind.row_kind);
  Alcotest.(check (list string))
    "field kinds come from the declared kind"
    [ "Int64"; "String"; "Bool" ]
    (List.map
       (fun (field : Row.field) -> Scalar.kind_to_string field.kind)
       relation.kind.row_kind);
  Alcotest.(check (list (option string)))
    "every field's qualifier is None" [ None; None; None ]
    (List.map
       (fun (field : Row.field) -> field.qualifier)
       relation.kind.row_kind);
  Alcotest.(check int)
    "literal carries no refinements" 0
    (List.length relation.kind.refinements)

let test_rows_match_the_literals_row () =
  with_literal_relation @@ fun relation ->
  let rows = List.of_seq relation.value in
  Alcotest.(check row_list_testable)
    "one row, values match the literal"
    [ [| Scalar.Int64 7L; Scalar.String "Pretzel"; Scalar.Bool true |] ]
    rows

let test_empty_rows_yields_an_empty_relation () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        Relation_literal { kind = literal_kind; rows = [] }
      in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             Alcotest.(check (list string))
               "empty form preserves the declared field names"
               [ "id"; "name"; "active" ]
               (List.map
                  (fun (field : Row.field) -> field.name)
                  relation.kind.row_kind);
             Alcotest.(check row_list_testable)
               "empty form yields no rows" []
               (List.of_seq relation.value))))

let () =
  Alcotest.run "eval_relation_literal"
    [
      ( "relation literal",
        [
          Alcotest.test_case "kind is the declared kind" `Quick
            test_kind_is_the_declared_kind;
          Alcotest.test_case "rows match the literal's row" `Quick
            test_rows_match_the_literals_row;
          Alcotest.test_case "empty rows yields an empty relation" `Quick
            test_empty_rows_yields_an_empty_relation;
        ] );
    ]
