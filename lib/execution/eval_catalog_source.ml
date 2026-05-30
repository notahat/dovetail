module Storage = Dovetail_storage
module Catalog = Dovetail_core.Catalog
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Enumerate the catalog's table names in cursor order, then fold across them
   with [Table_access.build_table_relation] so every per-table cursor is open
   at the moment [continue] is called. Hands the assembled [Catalog.value]
   down as [Term.Catalog_value]. Each per-table relation is tagged [`Set] --
   every base table in storage is a set today. *)
let evaluate environment transaction continue =
  let table_names = Storage.Catalog.list_table_names environment transaction in
  let rec collect collected = function
    | [] ->
        let relations = List.rev collected in
        continue (Term.Catalog_value ({ relations } : Catalog.value))
    | table_name :: rest ->
        let* relation =
          Table_access.build_table_relation environment transaction ~table_name
        in
        collect
          ((table_name, (relation : [ `Set ] Relation.t)) :: collected)
          rest
  in
  collect [] table_names
