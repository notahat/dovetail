type field = { name : string; kind : Scalar.kind; qualifier : string option }
type kind = field list
type data = Scalar.value array
type column_reference = { qualifier : string option; name : string }

(* Render a [column_reference] in dotted form (or bare, when unqualified) for
   inclusion in error messages. *)
let format_column_reference = function
  | { qualifier = Some qualifier; name } -> qualifier ^ "." ^ name
  | { qualifier = None; name } -> name

let format_field_name (field : field) =
  format_column_reference { qualifier = field.qualifier; name = field.name }

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
