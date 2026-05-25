(** Tests for [Core.Catalog] — type shape and construction. *)

open Dovetail_core

let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let empty_users_relation : [ `Set ] Relation.t =
  { kind = users_kind; value = Seq.empty }

let empty_orders_relation : [ `Set ] Relation.t =
  { kind = orders_kind; value = Seq.empty }

let test_kind_preserves_table_name_order () =
  let kind : Catalog.kind =
    { relation_kinds = [ ("orders", orders_kind); ("users", users_kind) ] }
  in
  Alcotest.(check (list string))
    "table names in declared order" [ "orders"; "users" ]
    (List.map fst kind.relation_kinds)

let test_empty_kind_has_no_relation_kinds () =
  let kind : Catalog.kind = { relation_kinds = [] } in
  Alcotest.(check int)
    "empty kind has zero entries" 0
    (List.length kind.relation_kinds)

let test_value_preserves_table_name_order () =
  let value : Catalog.value =
    {
      relations =
        [ ("orders", empty_orders_relation); ("users", empty_users_relation) ];
    }
  in
  Alcotest.(check (list string))
    "table names in declared order" [ "orders"; "users" ]
    (List.map fst value.relations)

let test_empty_value_has_no_relations () =
  let value : Catalog.value = { relations = [] } in
  Alcotest.(check int)
    "empty value has zero entries" 0
    (List.length value.relations)

let test_term_catalog_value_arm_round_trips () =
  let value : Catalog.value =
    { relations = [ ("users", empty_users_relation) ] }
  in
  match (Term.Catalog_value value : _ Term.t) with
  | Catalog_value retrieved ->
      Alcotest.(check (list string))
        "round-trips through the Term arm" [ "users" ]
        (List.map fst retrieved.relations)
  | _ -> Alcotest.fail "expected Catalog_value arm"

let test_term_catalog_kind_arm_round_trips () =
  let kind : Catalog.kind = { relation_kinds = [ ("users", users_kind) ] } in
  match (Term.Catalog_kind kind : _ Term.t) with
  | Catalog_kind retrieved ->
      Alcotest.(check (list string))
        "round-trips through the Term arm" [ "users" ]
        (List.map fst retrieved.relation_kinds)
  | _ -> Alcotest.fail "expected Catalog_kind arm"

let () =
  Alcotest.run "catalog"
    [
      ( "kind",
        [
          Alcotest.test_case "preserves the declared table-name order" `Quick
            test_kind_preserves_table_name_order;
          Alcotest.test_case "an empty kind has no relation kinds" `Quick
            test_empty_kind_has_no_relation_kinds;
        ] );
      ( "value",
        [
          Alcotest.test_case "preserves the declared table-name order" `Quick
            test_value_preserves_table_name_order;
          Alcotest.test_case "an empty value has no relations" `Quick
            test_empty_value_has_no_relations;
        ] );
      ( "term_arms",
        [
          Alcotest.test_case "Catalog_value round-trips through Term.t" `Quick
            test_term_catalog_value_arm_round_trips;
          Alcotest.test_case "Catalog_kind round-trips through Term.t" `Quick
            test_term_catalog_kind_arm_round_trips;
        ] );
    ]
