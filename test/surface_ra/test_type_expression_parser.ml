(** Tests for [Parser.parse_row_type] and [Parser.parse_relation_type] — the
    standalone type-expression entry points. The grammar is not yet wired into
    the pipeline grammar; these tests exercise the new productions directly. *)

open Dovetail_surface_ra
module Scalar = Dovetail_core.Scalar

(* Comparing [type_expression] structurally is enough; the testable's pretty-
   printer prints a fixed tag because Alcotest only displays it on failure. *)
let type_expression_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<type-expression>")) ( = )

let parses_row_type input expected =
  match Parser.parse_row_type input with
  | Ok actual ->
      Alcotest.(check type_expression_testable)
        (Printf.sprintf "%S parses as a row type" input)
        expected actual
  | Error message ->
      Alcotest.failf "expected %S to parse as a row type but got error: %s"
        input message

let parses_relation_type input expected =
  match Parser.parse_relation_type input with
  | Ok actual ->
      Alcotest.(check type_expression_testable)
        (Printf.sprintf "%S parses as a relation type" input)
        expected actual
  | Error message ->
      Alcotest.failf "expected %S to parse as a relation type but got error: %s"
        input message

let rejects_row_type input =
  match Parser.parse_row_type input with
  | Ok _ ->
      Alcotest.failf "expected %S to be rejected as a row type, but it parsed"
        input
  | Error _ -> ()

let rejects_relation_type input =
  match Parser.parse_relation_type input with
  | Ok _ ->
      Alcotest.failf
        "expected %S to be rejected as a relation type, but it parsed" input
  | Error _ -> ()

(* Build a [type_field] inline so tests read like the surface text. *)
let field name (kind : Scalar.kind) : Ast.type_field =
  { qualifier = None; name; kind }

let qualified_field ~qualifier ~name (kind : Scalar.kind) : Ast.type_field =
  { qualifier = Some qualifier; name; kind }

(* Build an AST-side [Primary_key] refinement from bare column names — the
   only spelling the surface grammar admits inside a [primary key (...)]
   clause. *)
let primary_key names : Ast.refinement =
  Primary_key
    (List.map
       (fun name : Ast.column_reference -> { qualifier = None; name })
       names)

let empty_type : Ast.type_expression = { fields = []; refinements = [] }

let single_field_type : Ast.type_expression =
  { fields = [ field "id" Int64 ]; refinements = [] }

let three_field_type : Ast.type_expression =
  {
    fields = [ field "id" Int64; field "name" String; field "active" Bool ];
    refinements = [];
  }

(* Row-type tests. *)

let test_row_type_parses_empty () = parses_row_type "()" empty_type

let test_row_type_parses_single_field () =
  parses_row_type "(id: int64)" single_field_type

let test_row_type_parses_multiple_fields () =
  parses_row_type "(id: int64, name: string, active: bool)" three_field_type

let test_row_type_tolerates_trailing_comma () =
  parses_row_type "(id: int64,)" single_field_type

let test_row_type_tolerates_extra_whitespace () =
  parses_row_type "(  id  :  int64  ,  name  :  string  ,  active  :  bool  )"
    three_field_type

let test_row_type_tolerates_surrounding_whitespace () =
  parses_row_type "   (id: int64)\n" single_field_type

let test_row_type_rejects_refinement () =
  rejects_row_type "(id: int64, primary key (id))"

let test_row_type_rejects_missing_colon () = rejects_row_type "(id int64)"
let test_row_type_rejects_unknown_kind () = rejects_row_type "(id: float)"

let test_row_type_rejects_kind_in_field_position () =
  (* Kind keywords are lowercase; an uppercase 'Int64' is not a kind here. *)
  rejects_row_type "(id: Int64)"

let test_row_type_rejects_missing_opening_paren () =
  rejects_row_type "id: int64)"

let test_row_type_rejects_missing_closing_paren () =
  rejects_row_type "(id: int64"

let test_row_type_rejects_trailing_garbage () =
  rejects_row_type "(id: int64) extra"

(* Relation-type tests. *)

let single_pk_type : Ast.type_expression =
  {
    fields = [ field "id" Int64; field "name" String ];
    refinements = [ primary_key [ "id" ] ];
  }

let compound_pk_type : Ast.type_expression =
  {
    fields =
      [ field "user_id" Int64; field "order_id" Int64; field "qty" Int64 ];
    refinements = [ primary_key [ "user_id"; "order_id" ] ];
  }

let test_relation_type_parses_empty () = parses_relation_type "()" empty_type

let test_relation_type_parses_without_refinements () =
  parses_relation_type "(id: int64, name: string, active: bool)"
    three_field_type

let test_relation_type_parses_single_column_primary_key () =
  parses_relation_type "(id: int64, name: string, primary key (id))"
    single_pk_type

let test_relation_type_parses_compound_primary_key () =
  parses_relation_type
    "(user_id: int64, order_id: int64, qty: int64, primary key (user_id, \
     order_id))"
    compound_pk_type

let test_relation_type_tolerates_whitespace_inside_primary_key () =
  parses_relation_type "(id: int64, primary  key  (  id  ))"
    { fields = [ field "id" Int64 ]; refinements = [ primary_key [ "id" ] ] }

let test_relation_type_rejects_empty_primary_key_column_list () =
  rejects_relation_type "(id: int64, primary key ())"

let test_relation_type_rejects_primary_key_without_key_keyword () =
  rejects_relation_type "(id: int64, primary (id))"

let test_relation_type_rejects_unknown_kind () =
  rejects_relation_type "(id: float)"

(* Reserved-word handling. *)

let test_field_name_int64_rejected () =
  (* A field named 'int64' would clash with the kind keyword at the kind
     position, but at the field-name position positional context could
     disambiguate. The parser still rejects so [int64] stays unambiguously
     a kind keyword inside type expressions. *)
  rejects_row_type "(int64: int64)"

let test_field_name_string_rejected () = rejects_row_type "(string: string)"
let test_field_name_bool_rejected () = rejects_row_type "(bool: bool)"

let test_field_name_primary_rejected () =
  (* 'primary' is reserved because it introduces the primary-key refinement
     clause. *)
  rejects_relation_type "(primary: int64)"

let test_field_name_key_rejected () =
  (* 'key' is reserved as half of the [primary key] clause. *)
  rejects_relation_type "(key: int64)"

(* Qualified field names. The dotted [qualifier.name] form parses the
   qualifier into the type field's [qualifier] slot. *)

let test_row_type_parses_qualified_field () =
  parses_row_type "(users.id: int64)"
    {
      fields = [ qualified_field ~qualifier:"users" ~name:"id" Int64 ];
      refinements = [];
    }

let test_row_type_parses_mixed_qualified_and_unqualified () =
  parses_row_type "(users.id: int64, name: string)"
    {
      fields =
        [
          qualified_field ~qualifier:"users" ~name:"id" Int64;
          field "name" String;
        ];
      refinements = [];
    }

let test_relation_type_parses_qualified_field_with_refinement () =
  parses_relation_type "(users.id: int64, users.name: string, primary key (id))"
    {
      fields =
        [
          qualified_field ~qualifier:"users" ~name:"id" Int64;
          qualified_field ~qualifier:"users" ~name:"name" String;
        ];
      refinements = [ primary_key [ "id" ] ];
    }

let test_row_type_rejects_qualified_field_with_reserved_name () =
  (* The qualifier prefix doesn't bypass the reserved-word check on the
     name half: a kind keyword in the name position is still ambiguous. *)
  rejects_row_type "(users.int64: int64)"

let () =
  Alcotest.run "type expression parser"
    [
      ( "row type",
        [
          Alcotest.test_case "parses the empty form" `Quick
            test_row_type_parses_empty;
          Alcotest.test_case "parses a single field" `Quick
            test_row_type_parses_single_field;
          Alcotest.test_case "parses multiple comma-separated fields" `Quick
            test_row_type_parses_multiple_fields;
          Alcotest.test_case "tolerates a trailing comma" `Quick
            test_row_type_tolerates_trailing_comma;
          Alcotest.test_case "tolerates extra whitespace between tokens" `Quick
            test_row_type_tolerates_extra_whitespace;
          Alcotest.test_case "tolerates leading and trailing whitespace" `Quick
            test_row_type_tolerates_surrounding_whitespace;
          Alcotest.test_case "rejects a primary-key refinement" `Quick
            test_row_type_rejects_refinement;
          Alcotest.test_case "rejects a field with no colon" `Quick
            test_row_type_rejects_missing_colon;
          Alcotest.test_case "rejects an unknown lowercase kind keyword" `Quick
            test_row_type_rejects_unknown_kind;
          Alcotest.test_case "rejects an uppercase kind in the kind position"
            `Quick test_row_type_rejects_kind_in_field_position;
          Alcotest.test_case "rejects a missing opening paren" `Quick
            test_row_type_rejects_missing_opening_paren;
          Alcotest.test_case "rejects a missing closing paren" `Quick
            test_row_type_rejects_missing_closing_paren;
          Alcotest.test_case "rejects trailing garbage after the type" `Quick
            test_row_type_rejects_trailing_garbage;
          Alcotest.test_case "parses a qualified field name" `Quick
            test_row_type_parses_qualified_field;
          Alcotest.test_case "parses a mix of qualified and unqualified fields"
            `Quick test_row_type_parses_mixed_qualified_and_unqualified;
          Alcotest.test_case
            "rejects a qualified field whose name half is a reserved word"
            `Quick test_row_type_rejects_qualified_field_with_reserved_name;
        ] );
      ( "relation type",
        [
          Alcotest.test_case "parses the empty form" `Quick
            test_relation_type_parses_empty;
          Alcotest.test_case "parses without a refinement clause" `Quick
            test_relation_type_parses_without_refinements;
          Alcotest.test_case "parses a single-column primary key" `Quick
            test_relation_type_parses_single_column_primary_key;
          Alcotest.test_case "parses a compound primary key" `Quick
            test_relation_type_parses_compound_primary_key;
          Alcotest.test_case
            "tolerates whitespace inside the primary key clause" `Quick
            test_relation_type_tolerates_whitespace_inside_primary_key;
          Alcotest.test_case "rejects an empty primary-key column list" `Quick
            test_relation_type_rejects_empty_primary_key_column_list;
          Alcotest.test_case "rejects primary without the key keyword" `Quick
            test_relation_type_rejects_primary_key_without_key_keyword;
          Alcotest.test_case "rejects an unknown lowercase kind keyword" `Quick
            test_relation_type_rejects_unknown_kind;
          Alcotest.test_case
            "parses qualified fields alongside a primary-key refinement" `Quick
            test_relation_type_parses_qualified_field_with_refinement;
        ] );
      ( "reserved words",
        [
          Alcotest.test_case "field named int64 is rejected" `Quick
            test_field_name_int64_rejected;
          Alcotest.test_case "field named string is rejected" `Quick
            test_field_name_string_rejected;
          Alcotest.test_case "field named bool is rejected" `Quick
            test_field_name_bool_rejected;
          Alcotest.test_case "field named primary is rejected" `Quick
            test_field_name_primary_rejected;
          Alcotest.test_case "field named key is rejected" `Quick
            test_field_name_key_rejected;
        ] );
    ]
