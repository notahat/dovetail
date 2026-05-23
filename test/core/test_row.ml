(** Tests for [Row]. *)

open Test_helpers

let users_row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = Some "users" };
    { name = "name"; kind = String; qualifier = Some "users" };
    { name = "email"; kind = String; qualifier = Some "users" };
    { name = "active"; kind = Bool; qualifier = Some "users" };
  ]

(* A row kind modelling the cross-product of users and orders: same-named
   [id] columns appear under different qualifiers, exercising the
   ambiguity-resolution path for unqualified references. *)
let cross_product_row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = Some "users" };
    { name = "name"; kind = String; qualifier = Some "users" };
    { name = "id"; kind = Int64; qualifier = Some "orders" };
    { name = "user_id"; kind = Int64; qualifier = Some "orders" };
  ]

let test_unqualified_lookup_returns_position_and_field () =
  match Row.find_field users_row_kind (column_reference "id") with
  | Ok (position, field) ->
      Alcotest.(check int) "id at position 0" 0 position;
      Alcotest.(check string) "field name" "id" field.name
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_unqualified_lookup_returns_position_for_later_field () =
  match Row.find_field users_row_kind (column_reference "active") with
  | Ok (position, field) ->
      Alcotest.(check int) "active at position 3" 3 position;
      Alcotest.(check string) "field name" "active" field.name
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_qualified_lookup_returns_position_and_field () =
  match
    Row.find_field users_row_kind
      (qualified_column_reference ~qualifier:"users" ~name:"id")
  with
  | Ok (position, _field) ->
      Alcotest.(check int) "users.id at position 0" 0 position
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_unqualified_lookup_unknown_returns_error () =
  match Row.find_field users_row_kind (column_reference "missing") with
  | Ok _ -> Alcotest.fail "expected an error for missing column"
  | Error message ->
      Alcotest.(check string)
        "error names the column" "unknown column \"missing\"" message

let test_qualified_lookup_unknown_returns_error () =
  match
    Row.find_field users_row_kind
      (qualified_column_reference ~qualifier:"orders" ~name:"id")
  with
  | Ok _ -> Alcotest.fail "expected an error for orders.id against users"
  | Error message ->
      Alcotest.(check string)
        "error names the qualified column" "unknown column \"orders.id\""
        message

let test_unqualified_lookup_ambiguous_returns_error_naming_qualifiers () =
  match Row.find_field cross_product_row_kind (column_reference "id") with
  | Ok _ -> Alcotest.fail "expected an ambiguity error"
  | Error message ->
      Alcotest.(check string)
        "error names both qualifiers"
        "ambiguous column reference \"id\": matches \"users.id\" and \
         \"orders.id\""
        message

let test_qualified_lookup_disambiguates_in_cross_product_kind () =
  match
    Row.find_field cross_product_row_kind
      (qualified_column_reference ~qualifier:"orders" ~name:"id")
  with
  | Ok (position, _field) ->
      Alcotest.(check int) "orders.id at position 2" 2 position
  | Error message -> Alcotest.failf "expected Ok, got Error %S" message

let test_format_column_reference_dotted_when_qualified () =
  Alcotest.(check string)
    "qualified" "users.id"
    (Row.format_column_reference
       (qualified_column_reference ~qualifier:"users" ~name:"id"))

let test_format_column_reference_bare_when_unqualified () =
  Alcotest.(check string)
    "unqualified" "id"
    (Row.format_column_reference (column_reference "id"))

let test_format_field_name_dotted_when_qualified () =
  let field : Row.field =
    { name = "id"; kind = Int64; qualifier = Some "users" }
  in
  Alcotest.(check string) "qualified" "users.id" (Row.format_field_name field)

let test_format_field_name_bare_when_unqualified () =
  let field : Row.field = { name = "id"; kind = Int64; qualifier = None } in
  Alcotest.(check string) "unqualified" "id" (Row.format_field_name field)

(* Render via [Row.format_kind] into a string for comparison against the
   expected surface text. *)
let format_kind_to_string kind =
  let buffer = Buffer.create 32 in
  let formatter = Format.formatter_of_buffer buffer in
  Row.format_kind formatter kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_kind_empty_renders_bare_parens () =
  Alcotest.(check string) "empty row kind" "()" (format_kind_to_string [])

let test_format_kind_single_field_renders_name_colon_type () =
  let kind : Row.kind = [ { name = "id"; kind = Int64; qualifier = None } ] in
  Alcotest.(check string)
    "single field" "(id: int64)"
    (format_kind_to_string kind)

let test_format_kind_multi_field_comma_separates () =
  let kind : Row.kind =
    [
      { name = "id"; kind = Int64; qualifier = None };
      { name = "name"; kind = String; qualifier = None };
      { name = "active"; kind = Bool; qualifier = None };
    ]
  in
  Alcotest.(check string)
    "multi-field row" "(id: int64, name: string, active: bool)"
    (format_kind_to_string kind)

let test_format_kind_drops_qualifiers () =
  let kind : Row.kind =
    [
      { name = "id"; kind = Int64; qualifier = Some "users" };
      { name = "name"; kind = String; qualifier = Some "users" };
    ]
  in
  Alcotest.(check string)
    "qualifiers are dropped at the surface" "(id: int64, name: string)"
    (format_kind_to_string kind)

let () =
  Alcotest.run "row"
    [
      ( "find_field",
        [
          Alcotest.test_case
            "unqualified reference returns position and field for the first \
             field"
            `Quick test_unqualified_lookup_returns_position_and_field;
          Alcotest.test_case
            "unqualified reference returns position and field for a later field"
            `Quick test_unqualified_lookup_returns_position_for_later_field;
          Alcotest.test_case "qualified reference returns position and field"
            `Quick test_qualified_lookup_returns_position_and_field;
          Alcotest.test_case "unknown unqualified column returns error" `Quick
            test_unqualified_lookup_unknown_returns_error;
          Alcotest.test_case
            "unknown qualified column returns error using dotted name" `Quick
            test_qualified_lookup_unknown_returns_error;
          Alcotest.test_case
            "ambiguous unqualified column names the conflicting qualifiers"
            `Quick
            test_unqualified_lookup_ambiguous_returns_error_naming_qualifiers;
          Alcotest.test_case
            "qualified reference disambiguates within a cross-product kind"
            `Quick test_qualified_lookup_disambiguates_in_cross_product_kind;
        ] );
      ( "format_column_reference",
        [
          Alcotest.test_case "renders dotted form when qualified" `Quick
            test_format_column_reference_dotted_when_qualified;
          Alcotest.test_case "renders bare form when unqualified" `Quick
            test_format_column_reference_bare_when_unqualified;
        ] );
      ( "format_field_name",
        [
          Alcotest.test_case "renders dotted form when field is qualified"
            `Quick test_format_field_name_dotted_when_qualified;
          Alcotest.test_case "renders bare form when field is unqualified"
            `Quick test_format_field_name_bare_when_unqualified;
        ] );
      ( "format_kind",
        [
          Alcotest.test_case "empty row kind renders as bare parens" `Quick
            test_format_kind_empty_renders_bare_parens;
          Alcotest.test_case "single field renders as name: type" `Quick
            test_format_kind_single_field_renders_name_colon_type;
          Alcotest.test_case "multiple fields are comma-separated" `Quick
            test_format_kind_multi_field_comma_separates;
          Alcotest.test_case "qualifiers are dropped at the surface" `Quick
            test_format_kind_drops_qualifiers;
        ] );
    ]
