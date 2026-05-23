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
        ] );
    ]
