(** Tests for [Relation_literal.schema_of], the kind-inference rule for the
    [RelationLiteral] IR constructor.

    The rule lives in one place so the [Logical] and [Physical] doc comments can
    point at it without each of them re-implementing the wording. These tests
    pin the rule's behaviour at the source level. *)

open Dovetail

let test_schema_of_infers_kinds_from_first_row () =
  let schema =
    Relation_literal.schema_of ~columns:[ "id"; "name"; "active" ]
      ~first_row:[ Value.Int64 7L; Value.String "Pretzel"; Value.Bool true ]
  in
  Alcotest.(check (list string))
    "field names come from columns" [ "id"; "name"; "active" ]
    (List.map (fun (field : Schema.field) -> field.name) schema.fields);
  Alcotest.(check (list string))
    "field kinds come from the first row's values"
    [ "Int64"; "String"; "Bool" ]
    (List.map
       (fun (field : Schema.field) -> Value.Kind.to_string field.kind)
       schema.fields)

let test_schema_of_leaves_qualifiers_absent () =
  let schema =
    Relation_literal.schema_of ~columns:[ "id" ] ~first_row:[ Value.Int64 1L ]
  in
  Alcotest.(check (list (option string)))
    "every field's qualifier is None" [ None ]
    (List.map (fun (field : Schema.field) -> field.qualifier) schema.fields)

let test_schema_of_yields_empty_primary_key () =
  let schema =
    Relation_literal.schema_of ~columns:[ "id" ] ~first_row:[ Value.Int64 1L ]
  in
  Alcotest.(check (list string))
    "derived relations carry no primary key" [] schema.primary_key

let test_schema_of_with_arity_mismatch_raises () =
  Alcotest.check_raises "row narrower than columns"
    (Invalid_argument
       "Relation_literal.schema_of: row has 1 value(s) but 2 column(s) declared")
    (fun () ->
      ignore
        (Relation_literal.schema_of ~columns:[ "id"; "name" ]
           ~first_row:[ Value.Int64 1L ]));
  Alcotest.check_raises "row wider than columns"
    (Invalid_argument
       "Relation_literal.schema_of: row has 3 value(s) but 1 column(s) declared")
    (fun () ->
      ignore
        (Relation_literal.schema_of ~columns:[ "id" ]
           ~first_row:[ Value.Int64 1L; Value.String "x"; Value.Bool true ]))

let () =
  Alcotest.run "relation_literal"
    [
      ( "schema_of",
        [
          Alcotest.test_case
            "field names come from columns, kinds from the first row's values"
            `Quick test_schema_of_infers_kinds_from_first_row;
          Alcotest.test_case "every field's qualifier is None" `Quick
            test_schema_of_leaves_qualifiers_absent;
          Alcotest.test_case "schema's primary_key is empty" `Quick
            test_schema_of_yields_empty_primary_key;
          Alcotest.test_case
            "row/column length mismatch raises Invalid_argument naming both \
             counts"
            `Quick test_schema_of_with_arity_mismatch_raises;
        ] );
    ]
