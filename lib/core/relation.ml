type refinement = Primary_key of string list
type kind = { row_kind : Row.kind; refinements : refinement list }

type 'tag t = {
  kind : kind;
  data : Row.data Seq.t;
}
  constraint 'tag = [< `Set | `Bag ]

let kind_of_schema (schema : Schema.t) : kind =
  let row_kind : Row.kind =
    List.map
      (fun (field : Schema.field) ->
        {
          Row.name = field.name;
          kind = field.kind;
          qualifier = field.qualifier;
        })
      schema.fields
  in
  let refinements =
    match schema.primary_key with [] -> [] | keys -> [ Primary_key keys ]
  in
  { row_kind; refinements }

let schema_of_kind (kind : kind) : Schema.t =
  let fields =
    List.map
      (fun (field : Row.field) ->
        {
          Schema.name = field.name;
          kind = field.kind;
          qualifier = field.qualifier;
        })
      kind.row_kind
  in
  let primary_key =
    List.find_map (function Primary_key keys -> Some keys) kind.refinements
    |> Option.value ~default:[]
  in
  { fields; primary_key }

let split_tuple (kind : kind) tuple =
  Schema.split_tuple (schema_of_kind kind) tuple

let assemble_tuple (kind : kind) ~primary_key_values ~non_primary_key_values =
  Schema.assemble_tuple (schema_of_kind kind) ~primary_key_values
    ~non_primary_key_values

(* Render a single value as the cell text that will appear in a table. No
   quoting, no escaping; the pretty-print is illustrative. This is
   deliberately distinct from {!Value.format}, which quotes strings so the
   value boundary is visible -- a presentational choice that fits an
   error message or a debug log but is wrong for cells laid out in a
   bordered grid where the column itself is the boundary. *)
let render_value = function
  | Value.Int64 number -> Int64.to_string number
  | Value.String text -> text
  | Value.Bool true -> "true"
  | Value.Bool false -> "false"

let is_numeric_kind : Value.kind -> bool = function
  | Int64 -> true
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

(* Repeat [piece] [count] times. The horizontal border glyph [─] is three
   UTF-8 bytes, so [String.make] -- which takes a single byte -- can't
   build the runs we need. *)
let repeat piece count =
  let buffer = Buffer.create (String.length piece * count) in
  for _ = 1 to count do
    Buffer.add_string buffer piece
  done;
  Buffer.contents buffer

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
  "│ " ^ String.concat " │ " parts ^ " │"

(* Build the horizontal rule under the header. The segments between
   corners are [─] runs two wider than the column to span the
   single-space padding inside each cell. *)
let format_header_separator widths =
  let segments =
    Array.map (fun width -> repeat "─" (width + 2)) widths |> Array.to_list
  in
  "├" ^ String.concat "┼" segments ^ "┤"

let print ?(formatter = Format.std_formatter) relation =
  let fields = relation.kind.row_kind in
  let headers = Array.of_list (List.map Row.format_field_name fields) in
  let right_aligns =
    Array.of_list
      (List.map (fun (field : Row.field) -> is_numeric_kind field.kind) fields)
  in
  let rendered_rows =
    relation.data
    |> Seq.map (fun row -> Array.map render_value row)
    |> List.of_seq
  in
  let widths = column_widths headers rendered_rows in
  Format.fprintf formatter "%s@\n" (format_row ~widths ~right_aligns headers);
  Format.fprintf formatter "%s@\n" (format_header_separator widths);
  List.iter
    (fun row ->
      Format.fprintf formatter "%s@\n" (format_row ~widths ~right_aligns row))
    rendered_rows
