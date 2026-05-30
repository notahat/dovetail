module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* Render a single cell as bare display text: digits for Int64, the unquoted
   string for String, and the lowercase keyword for Bool. Diverges from
   Scalar.format, which quotes strings for round-tripping. *)
let cell_text (value : Scalar.value) =
  match value with
  | Scalar.Int64 number -> Int64.to_string number
  | Scalar.String text -> text
  | Scalar.Bool boolean -> if boolean then "true" else "false"

(* Pad [text] to [width] for a cell of the given field's kind: Int64
   right-aligns, String and Bool left-align. *)
let align (field : Row.field) width text =
  let padding = String.make (width - String.length text) ' ' in
  match field.kind with
  | Scalar.Int64 -> padding ^ text
  | Scalar.String | Scalar.Bool -> text ^ padding

(* Centre [text] within [width], with any odd extra space on the right,
   matching psql's header placement. *)
let center width text =
  let total_padding = width - String.length text in
  let left = total_padding / 2 in
  String.make left ' ' ^ text ^ String.make (total_padding - left) ' '

(* Surround a column piece with the single-space cell padding and join columns
   with the [|] separator. *)
let join_cells pieces =
  String.concat "|" (List.map (fun piece -> " " ^ piece ^ " ") pieces)

(* Per-column layout: the field, its position in the row, and its display width
   -- the wider of the bare header name and the widest rendered cell. *)
let column_layout row_kind rows =
  List.mapi
    (fun index (field : Row.field) ->
      let width =
        List.fold_left
          (fun widest row -> max widest (String.length (cell_text row.(index))))
          (String.length field.name) rows
      in
      (index, field, width))
    row_kind

let render_header layout =
  join_cells
    (List.map
       (fun (_, (field : Row.field), width) -> center width field.name)
       layout)

let render_rule layout =
  String.concat "+"
    (List.map (fun (_, _, width) -> String.make (width + 2) '-') layout)

let render_row layout row =
  join_cells
    (List.map
       (fun (index, field, width) -> align field width (cell_text row.(index)))
       layout)

let render_footer row_count =
  if row_count = 1 then "(1 row)" else Printf.sprintf "(%d rows)" row_count

let format formatter relation =
  let row_kind = relation.Relation.kind.row_kind in
  let rows = List.of_seq relation.Relation.value in
  let layout = column_layout row_kind rows in
  let lines =
    render_header layout :: render_rule layout
    :: List.map (render_row layout) rows
    @ [ render_footer (List.length rows) ]
  in
  Format.pp_print_string formatter (String.concat "\n" lines)
