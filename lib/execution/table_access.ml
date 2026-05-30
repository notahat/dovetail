module Relation = Dovetail_core.Relation
module Storage = Dovetail_storage

(* A binding operator for CPS-shaped actions. [let* x = action in body]
   desugars to [( let* ) action (fun x -> body)], which here is just
   [action (fun x -> body)] -- the operator is the identity. It exists
   purely to flatten the nested continuations of the storage helpers, whose
   final argument is the continuation. *)
let ( let* ) action continue = action continue

(* Look up the kind and storage handle for a table referenced in a plan.
   [Plan.Typecheck] guarantees the catalog has a kind for [table_name]; the
   [None] arm here would only fire if a caller bypassed Typecheck.
   Raises [Failure] if the catalog has a kind but no storage subDB
   exists (a true catalog/storage divergence). *)
let lookup_table_resources environment transaction table_name =
  let kind =
    match Storage.Catalog.get environment transaction ~table_name with
    | Some kind -> kind
    (* Typecheck has validated every table reference. *)
    | None -> assert false
  in
  let table_map =
    match
      Storage.Engine.open_map environment transaction
        ~name:(Storage.Catalog.table_subdb_name table_name)
    with
    | Some map -> map
    | None ->
        failwith
          (Printf.sprintf
             "Eval: catalog has kind for %S but no storage subDB exists"
             table_name)
  in
  (kind, table_map)

(* Build a [Relation.t] for [table_name] from its catalog entry and storage
   subDB, opening a cursor for the duration of [continue]. The relation's
   [value] seq pulls key-value pairs directly from the live cursor, so it
   is valid only while [continue] runs. The multiplicity tag is left
   polymorphic; callers commit to [`Bag] (the full-scan source) or [`Set]
   (the catalog source) at the call site. *)
let build_table_relation environment transaction ~table_name continue =
  let kind, table_map =
    lookup_table_resources environment transaction table_name
  in
  let* pairs = Storage.Engine.with_iter_seq table_map transaction in
  let value = Seq.map (Storage.Row_codec.decode_row kind) pairs in
  continue ({ kind; value } : _ Relation.t)
