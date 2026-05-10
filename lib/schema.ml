type field = { name : string; kind : Value.Kind.t; qualifier : string option }
type t = { fields : field list; primary_key : string list }
type tuple = Value.t array
type column_reference = { qualifier : string option; name : string }

(* Render a [column_reference] in dotted form (or bare, when unqualified) for
   inclusion in error messages. *)
let format_column_reference = function
  | { qualifier = Some qualifier; name } -> qualifier ^ "." ^ name
  | { qualifier = None; name } -> name

let format_field_name (field : field) =
  format_column_reference { qualifier = field.qualifier; name = field.name }

(* Walk [schema.fields], pairing each field with its zero-based position and
   keeping the ones whose name matches [name]. *)
let fields_with_position_matching_name (schema : t) name =
  let rec scan position fields =
    match fields with
    | [] -> []
    | (field : field) :: rest when field.name = name ->
        (position, field) :: scan (position + 1) rest
    | _ :: rest -> scan (position + 1) rest
  in
  scan 0 schema.fields

let find_field schema reference =
  match reference with
  | { qualifier = Some required_qualifier; name } -> (
      let matching =
        fields_with_position_matching_name schema name
        |> List.filter (fun (_position, (field : field)) ->
            field.qualifier = Some required_qualifier)
      in
      match matching with
      | [ result ] -> Ok result
      | [] ->
          Error
            (Printf.sprintf "unknown column %S"
               (format_column_reference reference))
      | _ :: _ :: _ ->
          (* A qualifier-plus-name combination should be unique within a
             schema. If a future operator generates duplicates we'd want to
             know about it; for now treat it as an internal invariant
             violation. *)
          Error
            (Printf.sprintf
               "internal error: column reference %S matches multiple fields"
               (format_column_reference reference)))
  | { qualifier = None; name } -> (
      let matching = fields_with_position_matching_name schema name in
      match matching with
      | [ result ] -> Ok result
      | [] ->
          Error
            (Printf.sprintf "unknown column %S"
               (format_column_reference reference))
      | _ :: _ :: _ ->
          let qualified_names =
            List.map
              (fun (_position, field) ->
                Printf.sprintf "%S" (format_field_name field))
              matching
          in
          Error
            (Printf.sprintf "ambiguous column reference %S: matches %s" name
               (String.concat " and " qualified_names)))

(* Look up the position of [primary_key_name] in [primary_key_names], so that
   we can pull the right value from the caller's PK-ordered values list. *)
let index_in_primary_key primary_key_names primary_key_name =
  let rec find index = function
    | [] -> None
    | head :: _ when head = primary_key_name -> Some index
    | _ :: rest -> find (index + 1) rest
  in
  find 0 primary_key_names

let assemble_tuple schema ~primary_key_values ~non_primary_key_values =
  let primary_key_array = Array.of_list primary_key_values in
  let expected_pk_count = List.length schema.primary_key in
  if Array.length primary_key_array <> expected_pk_count then
    invalid_arg
      (Printf.sprintf
         "Schema.assemble_tuple: expected %d primary-key value(s), got %d"
         expected_pk_count
         (Array.length primary_key_array));
  let expected_non_pk_count = List.length schema.fields - expected_pk_count in
  if List.length non_primary_key_values <> expected_non_pk_count then
    invalid_arg
      (Printf.sprintf
         "Schema.assemble_tuple: expected %d non-primary-key value(s), got %d"
         expected_non_pk_count
         (List.length non_primary_key_values));
  let non_primary_key_remaining = ref non_primary_key_values in
  let take_non_primary_key () =
    match !non_primary_key_remaining with
    | [] -> assert false
    | head :: rest ->
        non_primary_key_remaining := rest;
        head
  in
  let resolve_field (field : field) =
    match index_in_primary_key schema.primary_key field.name with
    | Some position -> primary_key_array.(position)
    | None -> take_non_primary_key ()
  in
  Array.of_list (List.map resolve_field schema.fields)
