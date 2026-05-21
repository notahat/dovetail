module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema

type field = { name : string; kind : Value.kind }

type t =
  | List_tables
  | Drop_table of { table_name : string }
  | Describe of { table_name : string }
  | Create_table of {
      table_name : string;
      fields : field list;
      primary_key : string list;
    }

type read_result =
  | Listed of string list
  | Described of { table_name : string; schema : Schema.t }

type write_result = Dropped of string | Created of string

let classify = function
  | List_tables | Describe _ -> `Read
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
  | List_tables | Drop_table _ | Describe _ -> Ok ()
  | Create_table { table_name; fields; primary_key } ->
      validate_create_table ~table_name ~fields ~primary_key

(* Adapt a stored [Schema.t] into a [Create_table]-shaped statement: drop
   the per-field qualifiers (the DDL surface has no notion of qualified
   columns) and preserve field order and primary-key order verbatim. The
   round-trip with the catalog's storage shape -- where every field's
   qualifier is [Some table_name] -- is restored by the [Create_table]
   executor when it reconstructs the [Schema.t]. *)
let of_schema ~table_name (schema : Schema.t) : t =
  let fields =
    List.map
      (fun (field : Schema.field) : field ->
        { name = field.name; kind = field.kind })
      schema.fields
  in
  Create_table { table_name; fields; primary_key = schema.primary_key }
