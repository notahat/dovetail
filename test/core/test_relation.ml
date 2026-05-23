(** Tests for [Relation]. *)

open Dovetail_core

(* A fixture-shaped kind for [users] with qualifiers set just like
   {!Fixture} writes them, so rendered headers show [users.<column>]. *)
let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* A kind with no qualifier on its fields. Stands in for derived relations
   that lose qualifier information (e.g. {!Projection.resolve} keeps the
   input's qualifier today, but a future expression-projection step might
   not), so the printer keeps working when [qualifier = None]. *)
let unqualified_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    refinements = [];
  }

let two_users : Row.value list =
  [
    [|
      Scalar.Int64 1L;
      Scalar.String "Alice";
      Scalar.String "alice@example.com";
      Scalar.Bool true;
    |];
    [|
      Scalar.Int64 10L;
      Scalar.String "Bob";
      Scalar.String "bob@example.com";
      Scalar.Bool false;
    |];
  ]

let render relation =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.print ~formatter relation;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_renders_aligned_table_with_qualified_headers () =
  let relation : [ `Bag ] Relation.t =
    { kind = users_kind; value = List.to_seq two_users }
  in
  let expected =
    String.concat "\n"
      [
        "│ users.id │ users.name │ users.email       │ users.active │";
        "├──────────┼────────────┼───────────────────┼──────────────┤";
        "│        1 │ Alice      │ alice@example.com │ true         │";
        "│       10 │ Bob        │ bob@example.com   │ false        │";
      ]
  in
  Alcotest.(check string) "rendered table" expected (render relation)

let test_renders_unqualified_headers_when_fields_have_no_qualifier () =
  let relation : [ `Bag ] Relation.t =
    {
      kind = unqualified_kind;
      value = List.to_seq [ [| Scalar.Int64 1L; Scalar.String "Alice" |] ];
    }
  in
  let expected =
    String.concat "\n" [ "│ id │ name  │"; "├────┼───────┤"; "│  1 │ Alice │" ]
  in
  Alcotest.(check string) "rendered table" expected (render relation)

let test_renders_header_only_when_empty () =
  let relation : [ `Bag ] Relation.t =
    { kind = users_kind; value = Seq.empty }
  in
  let expected =
    String.concat "\n"
      [
        "│ users.id │ users.name │ users.email │ users.active │";
        "├──────────┼────────────┼─────────────┼──────────────┤";
      ]
  in
  Alcotest.(check string) "header-only table" expected (render relation)

let row_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<row>")) ( = )

let values_list_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<values>")) ( = )

(* A kind where the primary key is in the middle of the row, exercising
   that [assemble_row] interleaves by field order rather than appending. *)
let mid_pk_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "name"; kind = String; qualifier = None };
        { name = "id"; kind = Int64; qualifier = None };
        { name = "active"; kind = Bool; qualifier = None };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let composite_pk_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "tenant"; kind = String; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
        { name = "id"; kind = Int64; qualifier = None };
      ];
    refinements = [ Primary_key [ "tenant"; "id" ] ];
  }

let test_assembles_in_field_order_with_leading_pk () =
  let assembled =
    Relation.assemble_row users_kind ~primary_key_values:[ Scalar.Int64 42L ]
      ~non_primary_key_values:
        [
          Scalar.String "Alice";
          Scalar.String "alice@example.com";
          Scalar.Bool true;
        ]
  in
  let expected : Row.value =
    [|
      Scalar.Int64 42L;
      Scalar.String "Alice";
      Scalar.String "alice@example.com";
      Scalar.Bool true;
    |]
  in
  Alcotest.(check row_testable) "leading PK" expected assembled

let test_assembles_with_pk_in_the_middle () =
  let assembled =
    Relation.assemble_row mid_pk_kind ~primary_key_values:[ Scalar.Int64 7L ]
      ~non_primary_key_values:[ Scalar.String "Bob"; Scalar.Bool false ]
  in
  let expected : Row.value =
    [| Scalar.String "Bob"; Scalar.Int64 7L; Scalar.Bool false |]
  in
  Alcotest.(check row_testable) "PK in middle" expected assembled

let test_assembles_composite_primary_key () =
  let assembled =
    Relation.assemble_row composite_pk_kind
      ~primary_key_values:[ Scalar.String "acme"; Scalar.Int64 3L ]
      ~non_primary_key_values:[ Scalar.String "Carol" ]
  in
  let expected : Row.value =
    [| Scalar.String "acme"; Scalar.String "Carol"; Scalar.Int64 3L |]
  in
  Alcotest.(check row_testable) "composite PK" expected assembled

let test_splits_row_with_leading_pk () =
  let row : Row.value =
    [|
      Scalar.Int64 42L;
      Scalar.String "Alice";
      Scalar.String "alice@example.com";
      Scalar.Bool true;
    |]
  in
  let primary_key_values, non_primary_key_values =
    Relation.split_row users_kind row
  in
  Alcotest.(check values_list_testable)
    "primary-key values" [ Scalar.Int64 42L ] primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values"
    [
      Scalar.String "Alice"; Scalar.String "alice@example.com"; Scalar.Bool true;
    ]
    non_primary_key_values

let test_splits_row_with_pk_in_the_middle () =
  let row : Row.value =
    [| Scalar.String "Bob"; Scalar.Int64 7L; Scalar.Bool false |]
  in
  let primary_key_values, non_primary_key_values =
    Relation.split_row mid_pk_kind row
  in
  Alcotest.(check values_list_testable)
    "primary-key values" [ Scalar.Int64 7L ] primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values in field order"
    [ Scalar.String "Bob"; Scalar.Bool false ]
    non_primary_key_values

let test_splits_row_with_composite_primary_key () =
  let row : Row.value =
    [| Scalar.String "acme"; Scalar.String "Carol"; Scalar.Int64 3L |]
  in
  let primary_key_values, non_primary_key_values =
    Relation.split_row composite_pk_kind row
  in
  Alcotest.(check values_list_testable)
    "primary-key values in primary-key order"
    [ Scalar.String "acme"; Scalar.Int64 3L ]
    primary_key_values;
  Alcotest.(check values_list_testable)
    "non-primary-key values" [ Scalar.String "Carol" ] non_primary_key_values

let test_split_is_the_inverse_of_assemble () =
  let row : Row.value =
    [| Scalar.String "acme"; Scalar.String "Carol"; Scalar.Int64 3L |]
  in
  let primary_key_values, non_primary_key_values =
    Relation.split_row composite_pk_kind row
  in
  let reassembled =
    Relation.assemble_row composite_pk_kind ~primary_key_values
      ~non_primary_key_values
  in
  Alcotest.(check row_testable)
    "split then assemble round-trips the row" row reassembled

let test_split_rejects_wrong_length_row () =
  let row : Row.value = [| Scalar.Int64 1L; Scalar.String "Alice" |] in
  Alcotest.check_raises "raises Invalid_argument"
    (Invalid_argument
       "Relation.split_row: row has 2 value(s) but kind declares 4 field(s)")
    (fun () -> ignore (Relation.split_row users_kind row))

(* Render via [Relation.format_kind] into a string for comparison against
   the expected surface text. *)
let format_kind_to_string kind =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.format_kind formatter kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_kind_without_refinements_is_a_row_type () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [];
    }
  in
  Alcotest.(check string)
    "no refinements" "(id: int64, name: string)"
    (format_kind_to_string kind)

let test_format_kind_with_single_column_primary_key () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "id" ] ];
    }
  in
  Alcotest.(check string)
    "single-column primary key" "(id: int64, name: string, primary key (id))"
    (format_kind_to_string kind)

let test_format_kind_with_composite_primary_key () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "order_id"; kind = Int64; qualifier = None };
          { name = "line"; kind = Int64; qualifier = None };
          { name = "sku"; kind = String; qualifier = None };
        ];
      refinements = [ Primary_key [ "order_id"; "line" ] ];
    }
  in
  Alcotest.(check string)
    "composite primary key"
    "(order_id: int64, line: int64, sku: string, primary key (order_id, line))"
    (format_kind_to_string kind)

let test_format_kind_drops_field_qualifiers () =
  Alcotest.(check string)
    "qualifiers stripped from surface output"
    "(id: int64, name: string, email: string, active: bool, primary key (id))"
    (format_kind_to_string users_kind)

(* Render via [Relation.format] into a string for comparison against the
   expected surface text. *)
let format_to_string relation =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.format formatter relation;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_renders_empty_relation_inline () =
  let relation : [ `Bag ] Relation.t =
    { kind = users_kind; value = Seq.empty }
  in
  let expected =
    "relation (id: int64, name: string, email: string, active: bool, primary \
     key (id)) {}"
  in
  Alcotest.(check string)
    "empty relation renders with inline braces" expected
    (format_to_string relation)

let test_format_renders_multi_row_relation_one_row_per_line () =
  let relation : [ `Bag ] Relation.t =
    { kind = users_kind; value = List.to_seq two_users }
  in
  let expected =
    String.concat "\n"
      [
        "relation (id: int64, name: string, email: string, active: bool, \
         primary key (id)) {";
        "  (id = 1, name = \"Alice\", email = \"alice@example.com\", active = \
         true),";
        "  (id = 10, name = \"Bob\", email = \"bob@example.com\", active = \
         false)";
        "}";
      ]
  in
  Alcotest.(check string)
    "multi-row relation renders one row per line" expected
    (format_to_string relation)

let test_format_renders_single_row_relation_on_its_own_line () =
  let relation : [ `Bag ] Relation.t =
    {
      kind = unqualified_kind;
      value = List.to_seq [ [| Scalar.Int64 1L; Scalar.String "Alice" |] ];
    }
  in
  let expected =
    String.concat "\n"
      [
        "relation (id: int64, name: string) {";
        "  (id = 1, name = \"Alice\")";
        "}";
      ]
  in
  Alcotest.(check string)
    "single-row relation still breaks onto lines" expected
    (format_to_string relation)

let () =
  Alcotest.run "relation"
    [
      ( "print",
        [
          Alcotest.test_case "renders an aligned table with qualified headers"
            `Quick test_renders_aligned_table_with_qualified_headers;
          Alcotest.test_case
            "renders bare headers when fields have no qualifier" `Quick
            test_renders_unqualified_headers_when_fields_have_no_qualifier;
          Alcotest.test_case
            "renders just the header when the relation has no rows" `Quick
            test_renders_header_only_when_empty;
        ] );
      ( "assemble_row",
        [
          Alcotest.test_case "interleaves values in field order with leading PK"
            `Quick test_assembles_in_field_order_with_leading_pk;
          Alcotest.test_case "interleaves values when PK sits in the middle"
            `Quick test_assembles_with_pk_in_the_middle;
          Alcotest.test_case "interleaves values for a composite primary key"
            `Quick test_assembles_composite_primary_key;
        ] );
      ( "split_row",
        [
          Alcotest.test_case "splits a row whose PK is the leading field" `Quick
            test_splits_row_with_leading_pk;
          Alcotest.test_case "splits a row whose PK sits in the middle" `Quick
            test_splits_row_with_pk_in_the_middle;
          Alcotest.test_case
            "splits a row with a composite primary key in PK order" `Quick
            test_splits_row_with_composite_primary_key;
          Alcotest.test_case "round-trips through assemble_row" `Quick
            test_split_is_the_inverse_of_assemble;
          Alcotest.test_case "rejects a row of the wrong length" `Quick
            test_split_rejects_wrong_length_row;
        ] );
      ( "format_kind",
        [
          Alcotest.test_case "without refinements renders as a row type" `Quick
            test_format_kind_without_refinements_is_a_row_type;
          Alcotest.test_case
            "with a single-column primary key appends a primary key clause"
            `Quick test_format_kind_with_single_column_primary_key;
          Alcotest.test_case
            "with a composite primary key lists key columns in order" `Quick
            test_format_kind_with_composite_primary_key;
          Alcotest.test_case "drops field qualifiers at the surface" `Quick
            test_format_kind_drops_field_qualifiers;
        ] );
      ( "format",
        [
          Alcotest.test_case
            "renders an empty relation with inline empty braces" `Quick
            test_format_renders_empty_relation_inline;
          Alcotest.test_case
            "renders a multi-row relation with one row per line" `Quick
            test_format_renders_multi_row_relation_one_row_per_line;
          Alcotest.test_case
            "renders a single-row relation with the row on its own line" `Quick
            test_format_renders_single_row_relation_on_its_own_line;
        ] );
    ]
