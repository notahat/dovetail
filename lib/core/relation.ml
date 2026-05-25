type refinement = Primary_key of string list
type kind = { row_kind : Row.kind; refinements : refinement list }

type 'tag t = {
  kind : kind;
  value : Row.value Seq.t;
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

(* Render a single refinement clause in the surface syntax. *)
let format_refinement formatter = function
  | Primary_key columns ->
      Format.fprintf formatter "primary key (%s)" (String.concat ", " columns)

let format_kind formatter (kind : kind) =
  let format_field formatter (field : Row.field) =
    Format.fprintf formatter "%s: %a"
      (Row.format_field_name field)
      Scalar.format_kind field.kind
  in
  let separator formatter () = Format.pp_print_string formatter ", " in
  Format.pp_print_string formatter "(";
  Format.pp_print_list ~pp_sep:separator format_field formatter kind.row_kind;
  (match (kind.row_kind, kind.refinements) with
  | [], [] | _ :: _, [] -> ()
  | [], _ :: _ ->
      Format.pp_print_list ~pp_sep:separator format_refinement formatter
        kind.refinements
  | _ :: _, _ :: _ ->
      separator formatter ();
      Format.pp_print_list ~pp_sep:separator format_refinement formatter
        kind.refinements);
  Format.pp_print_string formatter ")"

(* Rendered through a vertical Format box so that when a relation is
   nested inside an enclosing box (e.g. a catalog literal), the rows
   indent further than at depth 0. The closing brace uses [@;<0 -2>]
   to back out to the column where the box opened. *)
let format formatter relation =
  let row_kind = relation.kind.row_kind in
  let rows = List.of_seq relation.value in
  match rows with
  | [] -> Format.fprintf formatter "relation %a {}" format_kind relation.kind
  | _ ->
      let format_row formatter row =
        Row.format formatter { kind = row_kind; value = row }
      in
      let separator formatter () = Format.fprintf formatter ",@," in
      Format.fprintf formatter "@[<v 2>relation %a {@," format_kind
        relation.kind;
      Format.pp_print_list ~pp_sep:separator format_row formatter rows;
      Format.fprintf formatter "@;<0 -2>}@]"
