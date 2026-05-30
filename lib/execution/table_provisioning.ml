module Storage = Dovetail_storage
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* The first element that appears more than once in [items], in order of
   second appearance. Returns [None] when every element is unique. Used
   by the create-table validator to point at the column or PK column
   that broke the uniqueness rule. *)
let first_duplicate items =
  let rec walk seen = function
    | [] -> None
    | item :: rest ->
        if List.mem item seen then Some item else walk (item :: seen) rest
  in
  walk [] items

(* Stamp [Some qualifier] onto every field of [kind]'s row kind, leaving
   refinements untouched. Used by the seeded create_table evaluator to
   turn a source row kind (unqualified after the qualifier-rejection
   check) into the target catalog kind, which is qualified by the new
   table's name to match the rest of the catalog. *)
let stamp_qualifier_on_kind ~qualifier (kind : Relation.kind) : Relation.kind =
  let row_kind =
    List.map
      (fun (field : Row.field) -> { field with qualifier = Some qualifier })
      kind.row_kind
  in
  { row_kind; refinements = kind.refinements }

(* Run the five structural checks on a target [kind] proposed for
   [table_name]: non-empty fields; no duplicate field names; non-empty
   primary key; PK columns drawn from the field list; no duplicate PK
   columns. Raises [Failure] with a [Create table: %S: ...] prefix on
   the first failing rule. Used by the seeded create_table evaluator,
   whose derived kind isn't visible to [Plan.Typecheck]; the empty form
   gets the same checks at typecheck time. *)
let validate_target_kind ~table_name (kind : Relation.kind) =
  let fail detail =
    failwith (Printf.sprintf "Create table: %S: %s" table_name detail)
  in
  let field_names =
    List.map (fun (field : Row.field) -> field.name) kind.row_kind
  in
  if field_names = [] then fail "column list is empty";
  (match first_duplicate field_names with
  | Some name -> fail (Printf.sprintf "column %S appears twice" name)
  | None -> ());
  let primary_key = Relation.primary_key_names kind in
  if primary_key = [] then fail "primary key is empty";
  (match
     List.find_opt (fun name -> not (List.mem name field_names)) primary_key
   with
  | Some name ->
      fail (Printf.sprintf "primary key column %S not in column list" name)
  | None -> ());
  match first_duplicate primary_key with
  | Some name ->
      fail (Printf.sprintf "primary key column %S appears twice" name)
  | None -> ()

(* Raise a [Create table: %S: table already exists] error if the catalog
   already binds [table_name]. Shared between the empty and seeded
   create_table evaluators. *)
let reject_existing_table environment transaction ~table_name =
  match Storage.Catalog.get environment transaction ~table_name with
  | None -> ()
  | Some _ ->
      failwith
        (Printf.sprintf "Create table: %S: table already exists" table_name)

(* Provision storage and catalog for a new table named [table_name] with
   shape [kind]. Creates the storage subDB before writing the catalog
   entry so anything raising in between rolls both halves back via the
   enclosing write transaction. Returns the freshly-opened map handle so
   a seeded create can write rows into it without re-opening. *)
let provision_table environment transaction ~table_name ~kind =
  let target_map =
    Storage.Engine.create_map environment transaction
      ~name:(Storage.Catalog.table_subdb_name table_name)
  in
  Storage.Catalog.put environment transaction ~table_name kind;
  target_map
