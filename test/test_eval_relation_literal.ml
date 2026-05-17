(** End-to-end tests for [Eval] on [Physical.RelationLiteral]. *)

open Dovetail
open Test_helpers

let test_relation_literal_yields_one_row () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      let plan : Physical.t =
        RelationLiteral
          {
            columns = [ "id"; "name"; "active" ];
            rows =
              [ [ Value.Int64 7L; Value.String "Pretzel"; Value.Bool true ] ];
          }
      in
      Eval.eval environment transaction plan (fun relation ->
          Alcotest.(check (list string))
            "schema field names" [ "id"; "name"; "active" ]
            (List.map
               (fun (field : Schema.field) -> field.name)
               relation.schema.fields);
          Alcotest.(check (list string))
            "schema field qualifiers are all empty" [ ""; ""; "" ]
            (List.map
               (fun (field : Schema.field) ->
                 match field.qualifier with None -> "" | Some q -> q)
               relation.schema.fields);
          Alcotest.(check (list string))
            "schema field kinds"
            [ "Int64"; "String"; "Bool" ]
            (List.map
               (fun (field : Schema.field) -> Value.Kind.to_string field.kind)
               relation.schema.fields);
          Alcotest.(check (list string))
            "schema primary key is empty" [] relation.schema.primary_key;
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "one row, values match the literal"
            [ [| Value.Int64 7L; Value.String "Pretzel"; Value.Bool true |] ]
            rows))

let () =
  Alcotest.run "eval_relation_literal"
    [
      ( "relation literal",
        [
          Alcotest.test_case
            "yields a one-row relation with value-inferred kinds and no \
             qualifier"
            `Quick test_relation_literal_yields_one_row;
        ] );
    ]
