(** Tests for [Term.format] — the unified pipeline-payload renderer. *)

open Dovetail_core

let kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let one_row : Row.value Seq.t =
  List.to_seq [ [| Scalar.Int64 1L; Scalar.String "Alice" |] ]

(* Render any [Term.format]-compatible value to a string. *)
let format_to_string term =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Term.format formatter term;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

(* Render a relation through [Relation.print] for direct comparison with the
   [Relation_value] arm. *)
let render_relation relation =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.print ~formatter relation;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let render_kind kind =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Format.fprintf formatter "%a@\n" Relation.format_kind kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_relation_value_renders_as_a_table () =
  let relation : [ `Bag ] Relation.t = { kind; value = one_row } in
  Alcotest.(check string)
    "Relation_value matches Relation.print output" (render_relation relation)
    (format_to_string (Term.Relation_value relation))

let test_relation_kind_renders_in_surface_syntax () =
  Alcotest.(check string)
    "Relation_kind matches Relation.format_kind output" (render_kind kind)
    (format_to_string (Term.Relation_kind kind))

let row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = None };
    { name = "name"; kind = String; qualifier = None };
  ]

let row : Row.t =
  { kind = row_kind; value = [| Scalar.Int64 1L; Scalar.String "Alice" |] }

let render_scalar_value value =
  let buffer = Buffer.create 16 in
  let formatter = Format.formatter_of_buffer buffer in
  Scalar.format formatter value;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let render_scalar_kind scalar_kind =
  let buffer = Buffer.create 16 in
  let formatter = Format.formatter_of_buffer buffer in
  Scalar.format_kind formatter scalar_kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let render_row row =
  let buffer = Buffer.create 32 in
  let formatter = Format.formatter_of_buffer buffer in
  Row.format formatter row;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let render_row_kind row_kind =
  let buffer = Buffer.create 32 in
  let formatter = Format.formatter_of_buffer buffer in
  Row.format_kind formatter row_kind;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_scalar_value_renders_via_scalar_format () =
  let value = Scalar.Int64 42L in
  Alcotest.(check string)
    "Scalar_value matches Scalar.format output"
    (render_scalar_value value)
    (format_to_string (Term.Scalar_value value))

let test_scalar_kind_renders_via_scalar_format_kind () =
  Alcotest.(check string)
    "Scalar_kind matches Scalar.format_kind output"
    (render_scalar_kind Scalar.Int64)
    (format_to_string (Term.Scalar_kind Scalar.Int64))

let test_row_value_renders_via_row_format () =
  Alcotest.(check string)
    "Row_value matches Row.format output" (render_row row)
    (format_to_string (Term.Row_value row))

let test_row_kind_renders_via_row_format_kind () =
  Alcotest.(check string)
    "Row_kind matches Row.format_kind output" (render_row_kind row_kind)
    (format_to_string (Term.Row_kind row_kind))

let () =
  Alcotest.run "term"
    [
      ( "format",
        [
          Alcotest.test_case "Relation_value renders as a table" `Quick
            test_relation_value_renders_as_a_table;
          Alcotest.test_case
            "Relation_kind renders in the surface relation-type syntax" `Quick
            test_relation_kind_renders_in_surface_syntax;
          Alcotest.test_case "Scalar_value renders via Scalar.format" `Quick
            test_scalar_value_renders_via_scalar_format;
          Alcotest.test_case "Scalar_kind renders via Scalar.format_kind" `Quick
            test_scalar_kind_renders_via_scalar_format_kind;
          Alcotest.test_case "Row_value renders via Row.format" `Quick
            test_row_value_renders_via_row_format;
          Alcotest.test_case "Row_kind renders via Row.format_kind" `Quick
            test_row_kind_renders_via_row_format_kind;
        ] );
    ]
