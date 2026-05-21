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
    ]
