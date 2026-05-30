(** Tests for [Sql_table]: the PostgreSQL-style result renderer used by the SQL
    surface. The renderer is a pure function over a materialised relation, so
    these tests build relations directly and assert on the exact rendered text
    -- column widths, alignment, centred bare-name headers, and the row-count
    footer. *)

open Dovetail_frontend
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* Build a [Row.field] with an optional qualifier, defaulting to the bare
   (unqualified) form a single-table scan produces. *)
let field ?qualifier name kind = { Row.name; kind; qualifier }

(* Build a relation from a field list and a list of rows, each row given as a
   list of scalar values in field order. Refinements are irrelevant to
   rendering, so the relation carries none. *)
let make_relation fields rows =
  {
    Relation.kind = { row_kind = fields; refinements = [] };
    value = List.to_seq (List.map Array.of_list rows);
  }

(* Render a relation to a string the way the REPL will, so assertions read as
   the user-visible table. *)
let render relation = Format.asprintf "%a" Sql_table.format relation

let check_renders description expected relation =
  Alcotest.(check string) description expected (render relation)

let test_renders_aligned_table_with_plural_footer () =
  let relation =
    make_relation
      [ field "id" Int64; field "name" String; field "active" Bool ]
      [
        [ Scalar.Int64 1L; Scalar.String "Alice"; Scalar.Bool true ];
        [ Scalar.Int64 42L; Scalar.String "Bob"; Scalar.Bool false ];
      ]
  in
  let expected =
    String.concat "\n"
      [
        " id | name  | active ";
        "----+-------+--------";
        "  1 | Alice | true   ";
        " 42 | Bob   | false  ";
        "(2 rows)";
      ]
  in
  check_renders "aligned table" expected relation

let test_right_aligns_int_left_aligns_string_and_bool () =
  let relation =
    make_relation
      [ field "n" Int64; field "label" String ]
      [
        [ Scalar.Int64 5L; Scalar.String "x" ];
        [ Scalar.Int64 1000L; Scalar.String "yz" ];
      ]
  in
  let expected =
    String.concat "\n"
      [
        "  n   | label ";
        "------+-------";
        "    5 | x     ";
        " 1000 | yz    ";
        "(2 rows)";
      ]
  in
  check_renders "int right, string left" expected relation

let test_strips_qualifier_from_headers () =
  let relation =
    make_relation
      [ field ~qualifier:"users" "id" Int64 ]
      [ [ Scalar.Int64 7L ] ]
  in
  let expected = String.concat "\n" [ " id "; "----"; "  7 "; "(1 row)" ] in
  check_renders "bare header" expected relation

let test_uses_singular_footer_for_one_row () =
  let relation =
    make_relation [ field "name" String ] [ [ Scalar.String "Alice" ] ]
  in
  let expected =
    String.concat "\n" [ " name  "; "-------"; " Alice "; "(1 row)" ]
  in
  check_renders "singular footer" expected relation

let test_renders_empty_relation_with_header_and_rule () =
  let relation = make_relation [ field "id" Int64; field "name" String ] [] in
  let expected =
    String.concat "\n" [ " id | name "; "----+------"; "(0 rows)" ]
  in
  check_renders "empty relation" expected relation

let () =
  Alcotest.run "sql_table"
    [
      ( "format",
        [
          Alcotest.test_case "renders an aligned table with a plural footer"
            `Quick test_renders_aligned_table_with_plural_footer;
          Alcotest.test_case
            "right-aligns int columns and left-aligns string and bool columns"
            `Quick test_right_aligns_int_left_aligns_string_and_bool;
          Alcotest.test_case "strips the qualifier from column headers" `Quick
            test_strips_qualifier_from_headers;
          Alcotest.test_case "uses a singular footer for a single row" `Quick
            test_uses_singular_footer_for_one_row;
          Alcotest.test_case "renders an empty relation with header and rule"
            `Quick test_renders_empty_relation_with_header_and_rule;
        ] );
    ]
