type 'tag t = {
  schema : Schema.t;
  tuples : Schema.tuple Seq.t;
}
  constraint 'tag = [< `Set | `Bag ]

(* Render a single value as the cell text that will appear in a table. No
   quoting, no escaping; slice 1's pretty-print is illustrative. *)
let render_value = function
  | Value.Int64 number -> Int64.to_string number
  | Value.String text -> text
  | Value.Bool true -> "true"
  | Value.Bool false -> "false"

let is_numeric_kind = function
  | Value.Kind.Int64 -> true
  | String | Bool -> false

(* Pad [text] with trailing or leading spaces to reach [width], depending on
   whether the column is right-aligned. *)
let pad_cell ~width ~right_align text =
  let padding = String.make (width - String.length text) ' ' in
  if right_align then padding ^ text else text ^ padding

(* Per-column maximum of header length and any cell length. *)
let column_widths headers rendered_rows =
  let widths = Array.map String.length headers in
  List.iter
    (fun row ->
      Array.iteri
        (fun column_index cell ->
          let cell_width = String.length cell in
          if cell_width > widths.(column_index) then
            widths.(column_index) <- cell_width)
        row)
    rendered_rows;
  widths

let format_row ~widths ~right_aligns cells =
  let parts =
    Array.mapi
      (fun column_index cell ->
        pad_cell ~width:widths.(column_index)
          ~right_align:right_aligns.(column_index)
          cell)
      cells
    |> Array.to_list
  in
  "| " ^ String.concat " | " parts ^ " |"

let format_separator widths =
  let dashes =
    Array.map (fun width -> String.make width '-') widths |> Array.to_list
  in
  "|-" ^ String.concat "-|-" dashes ^ "-|"

let print ?(formatter = Format.std_formatter) relation =
  let fields = relation.schema.fields in
  let headers =
    Array.of_list (List.map (fun (field : Schema.field) -> field.name) fields)
  in
  let right_aligns =
    Array.of_list
      (List.map
         (fun (field : Schema.field) -> is_numeric_kind field.kind)
         fields)
  in
  let rendered_rows =
    relation.tuples
    |> Seq.map (fun tuple -> Array.map render_value tuple)
    |> List.of_seq
  in
  let widths = column_widths headers rendered_rows in
  Format.fprintf formatter "%s@\n" (format_row ~widths ~right_aligns headers);
  Format.fprintf formatter "%s@\n" (format_separator widths);
  List.iter
    (fun row ->
      Format.fprintf formatter "%s@\n" (format_row ~widths ~right_aligns row))
    rendered_rows
