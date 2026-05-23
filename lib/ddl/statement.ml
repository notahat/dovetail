module Scalar = Dovetail_core.Scalar

type field = { name : string; kind : Scalar.kind }

type t =
  | List_tables
  | Drop_table of { table_name : string }
  | Create_table of {
      table_name : string;
      fields : field list;
      primary_key : string list;
    }

type read_result = Listed of string list
type write_result = Dropped of string | Created of string

let classify = function
  | List_tables -> `Read
  | Drop_table _ | Create_table _ -> `Write

(* The first element that appears more than once in [items], in order of
   second appearance. Returns [None] when every element is unique. Used by
   [validate] to point at the column or primary-key name that broke the
   uniqueness rule. *)
let find_duplicate items =
  let rec walk seen = function
    | [] -> None
    | item :: rest ->
        if List.mem item seen then Some item else walk (item :: seen) rest
  in
  walk [] items

(* Structural checks for a [Create_table] statement, returning [Ok ()] or
   the first failing rule's user-facing error string. Split out from
   [validate] so the [Create_table] case stays under 35 lines and the
   short-circuit order is easy to read top-to-bottom. *)
let validate_create_table ~table_name ~fields ~primary_key =
  let ( let* ) = Result.bind in
  let fail detail =
    Error (Printf.sprintf "DDL: create table %S: %s" table_name detail)
  in
  let field_names = List.map (fun (field : field) -> field.name) fields in
  let* () = if fields = [] then fail "column list is empty" else Ok () in
  let* () =
    match find_duplicate field_names with
    | Some name -> fail (Printf.sprintf "column %S appears twice" name)
    | None -> Ok ()
  in
  let* () = if primary_key = [] then fail "primary key is empty" else Ok () in
  let* () =
    match
      List.find_opt (fun name -> not (List.mem name field_names)) primary_key
    with
    | Some name ->
        fail (Printf.sprintf "primary key column %S not in column list" name)
    | None -> Ok ()
  in
  match find_duplicate primary_key with
  | Some name ->
      fail (Printf.sprintf "primary key column %S appears twice" name)
  | None -> Ok ()

let validate = function
  | List_tables | Drop_table _ -> Ok ()
  | Create_table { table_name; fields; primary_key } ->
      validate_create_table ~table_name ~fields ~primary_key
