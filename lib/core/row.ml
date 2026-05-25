type field = { name : string; kind : Scalar.kind; qualifier : string option }
type kind = field list
type value = Scalar.value array
type t = { kind : kind; value : value }
type column_reference = { qualifier : string option; name : string }

(* Render a [column_reference] in dotted form (or bare, when unqualified) for
   inclusion in error messages. *)
let format_column_reference = function
  | { qualifier = Some qualifier; name } -> qualifier ^ "." ^ name
  | { qualifier = None; name } -> name

let format_field_name (field : field) =
  format_column_reference { qualifier = field.qualifier; name = field.name }

let format_kind formatter (kind : kind) =
  let format_field formatter (field : field) =
    Format.fprintf formatter "%s: %a" (format_field_name field)
      Scalar.format_kind field.kind
  in
  let separator formatter () = Format.pp_print_string formatter ", " in
  Format.pp_print_string formatter "(";
  Format.pp_print_list ~pp_sep:separator format_field formatter kind;
  Format.pp_print_string formatter ")"

let format formatter (row : t) =
  let pairs = List.combine row.kind (Array.to_list row.value) in
  let format_pair formatter ((field : field), value) =
    Format.fprintf formatter "%s = %a" (format_field_name field) Scalar.format
      value
  in
  let separator formatter () = Format.pp_print_string formatter ", " in
  Format.pp_print_string formatter "(";
  Format.pp_print_list ~pp_sep:separator format_pair formatter pairs;
  Format.pp_print_string formatter ")"

(* Walk [row_kind], pairing each field with its zero-based position and
   keeping the ones whose name matches [name]. *)
let fields_with_position_matching_name (row_kind : kind) name =
  let rec scan position fields =
    match fields with
    | [] -> []
    | (field : field) :: rest when field.name = name ->
        (position, field) :: scan (position + 1) rest
    | _ :: rest -> scan (position + 1) rest
  in
  scan 0 row_kind

(* Find the first pair of fields in [row_kind] that share a bare [name] but
   carry different qualifiers. Returns [Some (name, first, second)] for the
   earliest such pair in source order, or [None] when every bare name is
   unique. The pair is what [unqualify_kind] needs to report a collision. *)
let find_bare_name_collision (row_kind : kind) =
  let rec scan = function
    | [] -> None
    | (field : field) :: rest -> (
        match
          List.find_opt (fun (other : field) -> other.name = field.name) rest
        with
        | Some other -> Some (field.name, field, other)
        | None -> scan rest)
  in
  scan row_kind

let unqualify_kind (row_kind : kind) =
  match find_bare_name_collision row_kind with
  | Some (name, first, second) ->
      Error
        (Printf.sprintf "collision on %S: fields %S and %S" name
           (format_field_name first) (format_field_name second))
  | None ->
      Ok
        (List.map
           (fun (field : field) -> { field with qualifier = None })
           row_kind)

let find_field (row_kind : kind) reference =
  let name_matches =
    fields_with_position_matching_name row_kind reference.name
  in
  let matching =
    match reference.qualifier with
    | None -> name_matches
    | Some required_qualifier ->
        List.filter
          (fun (_position, (field : field)) ->
            field.qualifier = Some required_qualifier)
          name_matches
  in
  match matching with
  | [ result ] -> Ok result
  | [] ->
      Error
        (Printf.sprintf "unknown column %S" (format_column_reference reference))
  | _ :: _ :: _ -> (
      match reference.qualifier with
      | Some _ ->
          (* A qualifier+name combination is unique within any row kind we
             construct: scans tag every field with the table's qualifier, and
             cross-product/join preserve the input qualifiers. Hitting this
             arm means an upstream operator produced a row kind that breaks
             that invariant. *)
          assert false
      | None ->
          let qualified_names =
            List.map
              (fun (_position, field) ->
                Printf.sprintf "%S" (format_field_name field))
              matching
          in
          Error
            (Printf.sprintf "ambiguous column reference %S: matches %s"
               reference.name
               (String.concat " and " qualified_names)))
