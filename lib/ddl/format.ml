module Value = Dovetail_core.Value

(* Render one column declaration on its own indented line, with the
   trailing comma the canonical form puts on every column (including
   the last). The two-space indent and the [name: Kind] separator are
   the canonical form's two formatting decisions for a column line. *)
let format_field (field : Statement.field) =
  Printf.sprintf "  %s: %s,\n" field.name (Value.kind_to_string field.kind)

(* Render a [Create_table] in the canonical multi-line form. The columns
   block is one [format_field] line per field; the closing line opens
   with [)] and names the primary key as a comma-space-separated list
   inside its own parens. No trailing newline -- the caller adds one. *)
let format_create_table ~table_name ~fields ~primary_key =
  let columns = String.concat "" (List.map format_field fields) in
  let primary_key_text = String.concat ", " primary_key in
  Printf.sprintf ":create table %s (\n%s) primary key (%s)" table_name columns
    primary_key_text

let statement = function
  | Statement.List_tables -> ":list tables"
  | Statement.Drop_table { table_name } -> ":drop table " ^ table_name
  | Statement.Describe { table_name } -> ":describe " ^ table_name
  | Statement.Create_table { table_name; fields; primary_key } ->
      format_create_table ~table_name ~fields ~primary_key
