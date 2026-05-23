type refinement = Primary_key of string list
type kind = { row_kind : Row.kind; refinements : refinement list }

type 'tag t = {
  kind : kind;
  data : Row.data Seq.t;
}
  constraint 'tag = [< `Set | `Bag ]

(* Extract the primary-key column names from a kind's refinements. Returns
   the empty list when no [Primary_key] refinement is present. *)
let primary_key_names (kind : kind) =
  List.find_map (function Primary_key keys -> Some keys) kind.refinements
  |> Option.value ~default:[]

(* Look up the position of [primary_key_name] in [primary_key_list], so that
   we can pull the right value from the caller's PK-ordered values list. *)
let index_in_primary_key primary_key_list primary_key_name =
  let rec find index = function
    | [] -> None
    | head :: _ when head = primary_key_name -> Some index
    | _ :: rest -> find (index + 1) rest
  in
  find 0 primary_key_list

(* Locate [primary_key_name] in [row_kind] and return its zero-based
   position. Internal invariant: catalog construction guarantees every name
   in a kind's primary key is present in its row_kind. *)
let position_of_primary_key_field (row_kind : Row.kind) primary_key_name =
  let rec find index = function
    | [] -> assert false
    | (field : Row.field) :: _ when field.name = primary_key_name -> index
    | _ :: rest -> find (index + 1) rest
  in
  find 0 row_kind

let split_row (kind : kind) row =
  let expected_length = List.length kind.row_kind in
  if Array.length row <> expected_length then
    invalid_arg
      (Printf.sprintf
         "Relation.split_row: row has %d value(s) but kind declares %d field(s)"
         (Array.length row) expected_length);
  let primary_key = primary_key_names kind in
  let primary_key_values =
    List.map
      (fun primary_key_name ->
        row.(position_of_primary_key_field kind.row_kind primary_key_name))
      primary_key
  in
  let is_primary_key_name name = List.mem name primary_key in
  let non_primary_key_values =
    List.mapi
      (fun position (field : Row.field) ->
        if is_primary_key_name field.name then None else Some row.(position))
      kind.row_kind
    |> List.filter_map Fun.id
  in
  (primary_key_values, non_primary_key_values)

let assemble_row (kind : kind) ~primary_key_values ~non_primary_key_values =
  let primary_key = primary_key_names kind in
  let primary_key_array = Array.of_list primary_key_values in
  let expected_primary_key_count = List.length primary_key in
  if Array.length primary_key_array <> expected_primary_key_count then
    invalid_arg
      (Printf.sprintf
         "Relation.assemble_row: expected %d primary-key value(s), got %d"
         expected_primary_key_count
         (Array.length primary_key_array));
  let expected_non_primary_key_count =
    List.length kind.row_kind - expected_primary_key_count
  in
  if List.length non_primary_key_values <> expected_non_primary_key_count then
    invalid_arg
      (Printf.sprintf
         "Relation.assemble_row: expected %d non-primary-key value(s), got %d"
         expected_non_primary_key_count
         (List.length non_primary_key_values));
  let non_primary_key_remaining = ref non_primary_key_values in
  let take_non_primary_key () =
    match !non_primary_key_remaining with
    (* The length check above guarantees one value per non-PK field, so the
       list cannot be exhausted before [resolve_field] stops asking. *)
    | [] -> assert false
    | head :: rest ->
        non_primary_key_remaining := rest;
        head
  in
  let resolve_field (field : Row.field) =
    match index_in_primary_key primary_key field.name with
    | Some position -> primary_key_array.(position)
    | None -> take_non_primary_key ()
  in
  Array.of_list (List.map resolve_field kind.row_kind)

(* Render a single value as the cell text that will appear in a table. No
   quoting, no escaping; the pretty-print is illustrative. This is
   deliberately distinct from {!Scalar.format}, which quotes strings so the
   value boundary is visible -- a presentational choice that fits an
   error message or a debug log but is wrong for cells laid out in a
   bordered grid where the column itself is the boundary. *)
let render_value = function
  | Scalar.Int64 number -> Int64.to_string number
  | Scalar.String text -> text
  | Scalar.Bool true -> "true"
  | Scalar.Bool false -> "false"

let is_numeric_kind : Scalar.kind -> bool = function
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
  let row_kind = relation.kind.row_kind in
  let headers = Array.of_list (List.map Row.format_field_name row_kind) in
  let right_aligns =
    Array.of_list
      (List.map
         (fun (field : Row.field) -> is_numeric_kind field.kind)
         row_kind)
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
