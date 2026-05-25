module Catalog = Dovetail_core.Catalog
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

type error =
  | Insert_column_mismatch of {
      table_name : string;
      missing : string list;
      extra : string list;
    }

(* Symmetric difference of [expected] and [actual] as two lists: the names
   in [expected] but not in [actual] and the names in [actual] but not in
   [expected]. Each result preserves the order of its source list. *)
let multiset_difference ~expected ~actual =
  let missing = List.filter (fun name -> not (List.mem name actual)) expected in
  let extra = List.filter (fun name -> not (List.mem name expected)) actual in
  (missing, extra)

let render = function
  | Insert_column_mismatch { table_name; missing; extra } ->
      let halves =
        (if missing = [] then []
         else
           [
             Printf.sprintf "missing column(s): %s" (String.concat ", " missing);
           ])
        @
        if extra = [] then []
        else
          [ Printf.sprintf "unknown column(s): %s" (String.concat ", " extra) ]
      in
      Printf.sprintf "Insert: into %S: %s" table_name
        (String.concat "; " halves)

(* Check that [literal_kind]'s field names are a permutation of
   [target_kind]'s. Emits a single [Insert_column_mismatch] carrying both
   halves of the symmetric difference, so the renderer can produce one
   combined message rather than splitting the report into two passes. *)
let check_insert_columns ~table_name ~(target_kind : Relation.kind)
    ~(literal_kind : Relation.kind) : error list =
  let target_column_names =
    List.map (fun (field : Row.field) -> field.name) target_kind.row_kind
  in
  let literal_column_names =
    List.map (fun (field : Row.field) -> field.name) literal_kind.row_kind
  in
  let missing, extra =
    multiset_difference ~expected:target_column_names
      ~actual:literal_column_names
  in
  if missing = [] && extra = [] then []
  else [ Insert_column_mismatch { table_name; missing; extra } ]

(* Errors specific to an [Insert] node: today, the literal source's column
   set against the target's. Unknown target tables pass through silently --
   [Translate] still raises for those. Non-literal sources have no
   compile-time kind to check against here. *)
let check_insert ~(catalog : Catalog.kind) ~table ~(source : Logical.t) :
    error list =
  match (List.assoc_opt table catalog.relation_kinds, source) with
  | Some target_kind, Relation_literal { kind = literal_kind; _ } ->
      check_insert_columns ~table_name:table ~target_kind ~literal_kind
  | _ -> []

(* Post-order walk: gather errors from each subtree, then add any errors
   contributed by the operator itself. *)
let rec collect_errors ~catalog (plan : Logical.t) : error list =
  match plan with
  | Scan _ | Relation_literal _ | Scalar_literal _ | Row_literal _
  | Drop_table _ | Create_table_empty _ | Catalog_source ->
      []
  | Restrict { input; _ }
  | Project { input; _ }
  | Unqualify { input }
  | Type_op { input }
  | Tables { input }
  | Create_table_seeded { source = input; _ } ->
      collect_errors ~catalog input
  | CrossProduct { left; right } ->
      collect_errors ~catalog left @ collect_errors ~catalog right
  | Insert { table; source } ->
      let source_errors = collect_errors ~catalog source in
      let insert_errors = check_insert ~catalog ~table ~source in
      source_errors @ insert_errors

let typecheck ~catalog plan =
  match collect_errors ~catalog plan with
  | [] -> Ok plan
  | errors -> Error errors
