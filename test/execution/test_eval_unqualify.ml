(** End-to-end tests for [Eval] on [Physical.Unqualify].

    Unqualify is a row-shape rewriter that strips the qualifier from every field
    of its input's row kind. The tests cover the two input shapes ([`Bag]
    relation and bare row), the collision-on-bare-name failure path, and the
    no-op when the input already has no qualifiers. *)

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

let row_testable : Row.t Alcotest.testable = Alcotest.testable Row.format ( = )

let with_environment_and_transaction body =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      body environment transaction)

let test_unqualify_strips_qualifiers_from_relation () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        Unqualify { input = FullScan { table = "users" } }
      in
      Eval.eval environment transaction plan
        (expect_relation (fun relation ->
             let qualifiers =
               List.map
                 (fun (field : Row.field) -> field.qualifier)
                 relation.kind.row_kind
             in
             Alcotest.(check (list (option string)))
               "every field of the result kind has qualifier = None"
               (List.map (fun _ -> None) relation.kind.row_kind)
               qualifiers;
             Alcotest.(check row_list_testable)
               "row values are unchanged" expected_users_rows
               (List.of_seq relation.value))))

let test_unqualify_is_identity_on_already_unqualified_relation () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let inner = Plan.Physical.FullScan { table = "users" } in
      let plan : Plan.Physical.t = Unqualify { input = inner } in
      Eval.eval environment transaction inner
        (expect_relation (fun before ->
             Eval.eval environment transaction plan
               (expect_relation (fun after ->
                    Alcotest.(check row_list_testable)
                      "unqualify on an already-unqualified relation is a no-op"
                      (List.of_seq before.value) (List.of_seq after.value))))))

let test_unqualify_rejects_collision_on_bare_name () =
  with_fixture_environment @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      let plan : Plan.Physical.t =
        Unqualify
          {
            input =
              Project
                {
                  input =
                    CrossProduct
                      {
                        left = FullScan { table = "users" };
                        right = FullScan { table = "orders" };
                      };
                  columns =
                    [
                      qualified_column_reference ~qualifier:"users" ~name:"id";
                      qualified_column_reference ~qualifier:"orders" ~name:"id";
                    ];
                };
          }
      in
      Alcotest.check_raises "collision on bare \"id\""
        (Failure
           "Eval: unqualify: collision on \"id\": fields \"users.id\" and \
            \"orders.id\"") (fun () ->
          Eval.eval environment transaction plan (fun _ -> ())))

let test_unqualify_strips_qualifiers_from_row () =
  with_environment_and_transaction @@ fun environment transaction ->
  let plan : Plan.Physical.t =
    Unqualify
      {
        input =
          Row_literal
            {
              fields =
                [
                  ( qualified_column_reference ~qualifier:"users" ~name:"id",
                    Scalar.Int64 1L );
                  ( qualified_column_reference ~qualifier:"users" ~name:"name",
                    Scalar.String "alice" );
                ];
            };
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
           "row literal becomes the same row with bare names" expected row))

let () =
  Alcotest.run "eval_unqualify"
    [
      ( "unqualify",
        [
          Alcotest.test_case
            "strips qualifiers from every field of a relation input" `Quick
            test_unqualify_strips_qualifiers_from_relation;
          Alcotest.test_case
            "is the identity on a relation that already has no qualifiers"
            `Quick test_unqualify_is_identity_on_already_unqualified_relation;
          Alcotest.test_case "rejects a collision on the stripped bare name"
            `Quick test_unqualify_rejects_collision_on_bare_name;
          Alcotest.test_case "strips qualifiers from a row literal input" `Quick
            test_unqualify_strips_qualifiers_from_row;
        ] );
    ]
