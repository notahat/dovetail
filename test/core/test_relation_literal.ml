(** Tests for [Relation_literal.kind_of], the kind-inference rule for the
    [RelationLiteral] IR constructor.

    The rule lives in one place so the [Logical] and [Physical] doc comments can
    point at it without each of them re-implementing the wording. These tests
    pin the rule's behaviour at the source level. *)

open Dovetail_core

let test_kind_of_infers_kinds_from_first_row () =
  let kind =
    Relation_literal.kind_of ~columns:[ "id"; "name"; "active" ]
      ~first_row:[ Scalar.Int64 7L; Scalar.String "Pretzel"; Scalar.Bool true ]
  in
  Alcotest.(check (list string))
    "field names come from columns" [ "id"; "name"; "active" ]
    (List.map (fun (field : Row.field) -> field.name) kind.row_kind);
  Alcotest.(check (list string))
    "field kinds come from the first row's values"
    [ "Int64"; "String"; "Bool" ]
    (List.map
       (fun (field : Row.field) -> Scalar.kind_to_string field.kind)
       kind.row_kind)

let test_kind_of_leaves_qualifiers_absent () =
  let kind =
    Relation_literal.kind_of ~columns:[ "id" ] ~first_row:[ Scalar.Int64 1L ]
  in
  Alcotest.(check (list (option string)))
    "every field's qualifier is None" [ None ]
    (List.map (fun (field : Row.field) -> field.qualifier) kind.row_kind)

let test_kind_of_yields_no_refinements () =
  let kind =
    Relation_literal.kind_of ~columns:[ "id" ] ~first_row:[ Scalar.Int64 1L ]
  in
  Alcotest.(check int)
    "derived relations carry no refinements" 0
    (List.length kind.refinements)

let test_kind_of_with_arity_mismatch_raises () =
  Alcotest.check_raises "row narrower than columns"
    (Invalid_argument
       "Relation_literal.kind_of: row has 1 value(s) but 2 column(s) declared")
    (fun () ->
      ignore
        (Relation_literal.kind_of ~columns:[ "id"; "name" ]
           ~first_row:[ Scalar.Int64 1L ]));
  Alcotest.check_raises "row wider than columns"
    (Invalid_argument
       "Relation_literal.kind_of: row has 3 value(s) but 1 column(s) declared")
    (fun () ->
      ignore
        (Relation_literal.kind_of ~columns:[ "id" ]
           ~first_row:[ Scalar.Int64 1L; Scalar.String "x"; Scalar.Bool true ]))

let () =
  Alcotest.run "relation_literal"
    [
      ( "kind_of",
        [
          Alcotest.test_case
            "field names come from columns, kinds from the first row's values"
            `Quick test_kind_of_infers_kinds_from_first_row;
          Alcotest.test_case "every field's qualifier is None" `Quick
            test_kind_of_leaves_qualifiers_absent;
          Alcotest.test_case "kind carries no refinements" `Quick
            test_kind_of_yields_no_refinements;
          Alcotest.test_case
            "row/column length mismatch raises Invalid_argument naming both \
             counts"
            `Quick test_kind_of_with_arity_mismatch_raises;
        ] );
    ]
