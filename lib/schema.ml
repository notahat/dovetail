type field = { name : string; kind : Value.Kind.t }
type t = { fields : field list; primary_key : string list }
type tuple = Value.t array

let find_field schema name =
  let rec scan position fields =
    match fields with
    | [] -> None
    | (field : field) :: _ when field.name = name -> Some (position, field)
    | _ :: rest -> scan (position + 1) rest
  in
  scan 0 schema.fields

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
  let resolve_field field =
    match index_in_primary_key schema.primary_key field.name with
    | Some position -> primary_key_array.(position)
    | None -> take_non_primary_key ()
  in
  Array.of_list (List.map resolve_field schema.fields)
