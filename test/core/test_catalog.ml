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

(* Render via [Catalog.format_kind] into a string for comparison against the
   expected surface text. *)
let format_kind_to_string kind =
  let buffer = Buffer.create 128 in
  let formatter = Format.formatter_of_buffer buffer in
  Catalog.format_kind formatter kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

(* Render via [Catalog.format] into a string for comparison against the
   expected surface text. *)
let format_to_string value =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Catalog.format formatter value;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_kind_empty_renders_inline () =
  let kind : Catalog.kind = { relation_kinds = [] } in
  Alcotest.(check string)
    "empty catalog kind renders inline" "catalog {}"
    (format_kind_to_string kind)

let test_format_kind_renders_entries_single_line () =
  let kind : Catalog.kind =
    { relation_kinds = [ ("orders", orders_kind); ("users", users_kind) ] }
  in
  let expected =
    "catalog { orders: (orders.id: int64, orders.user_id: int64, primary key \
     (id)), users: (users.id: int64, users.name: string, primary key (id)) }"
  in
  Alcotest.(check string)
    "catalog kind renders each entry as name: T" expected
    (format_kind_to_string kind)

let test_format_empty_value_renders_inline () =
  let value : Catalog.value = { relations = [] } in
  Alcotest.(check string)
    "empty catalog value renders inline" "catalog {}" (format_to_string value)

let test_format_value_with_empty_relations_breaks_across_lines () =
  let value : Catalog.value =
    {
      relations =
        [ ("orders", empty_orders_relation); ("users", empty_users_relation) ];
    }
  in
  let expected =
    String.concat "\n"
      [
        "catalog {";
        "  orders = relation (orders.id: int64, orders.user_id: int64, primary \
         key (id)) {},";
        "  users = relation (users.id: int64, users.name: string, primary key \
         (id)) {}";
        "}";
      ]
  in
  Alcotest.(check string)
    "catalog value breaks each entry onto its own line" expected
    (format_to_string value)

let users_with_one_row : [ `Set ] Relation.t =
  {
    kind = users_kind;
    value = List.to_seq [ [| Scalar.Int64 1L; Scalar.String "Alice" |] ];
  }

let test_format_value_with_rows_nests_relation_rows () =
  let value : Catalog.value =
    { relations = [ ("users", users_with_one_row) ] }
  in
  let expected =
    String.concat "\n"
      [
        "catalog {";
        "  users = relation (users.id: int64, users.name: string, primary key \
         (id)) {";
        "    (users.id = 1, users.name = \"Alice\")";
        "  }";
        "}";
      ]
  in
  Alcotest.(check string)
    "nested relation rows indent under the catalog's vertical box" expected
    (format_to_string value)

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
      ( "format_kind",
        [
          Alcotest.test_case "renders an empty catalog kind inline" `Quick
            test_format_kind_empty_renders_inline;
          Alcotest.test_case "renders each entry as name: T on a single line"
            `Quick test_format_kind_renders_entries_single_line;
        ] );
      ( "format",
        [
          Alcotest.test_case "renders an empty catalog value inline" `Quick
            test_format_empty_value_renders_inline;
          Alcotest.test_case
            "breaks each entry onto its own line for empty relations" `Quick
            test_format_value_with_empty_relations_breaks_across_lines;
          Alcotest.test_case
            "nests a relation's rows under the catalog's vertical box" `Quick
            test_format_value_with_rows_nests_relation_rows;
        ] );
      ( "term_arms",
        [
          Alcotest.test_case "Catalog_value round-trips through Term.t" `Quick
            test_term_catalog_value_arm_round_trips;
          Alcotest.test_case "Catalog_kind round-trips through Term.t" `Quick
            test_term_catalog_kind_arm_round_trips;
        ] );
    ]
