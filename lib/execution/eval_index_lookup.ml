module Storage = Dovetail_storage
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* Encode [key], probe the table's storage subDB with [Storage.Engine.get], and
   hand [continue] a relation whose [value] seq has either one element
   (the decoded row) or zero (no row at that key). The seq is [Seq.empty]
   or [Seq.return _] -- a regular OCaml seq, not a live cursor -- so there
   is no resource scope to keep open across [continue]; the relation can
   safely be consumed at any point. *)
let evaluate environment transaction ~table ~key continue =
  let kind, table_map =
    Table_access.lookup_table_resources environment transaction table
  in
  let encoded_key = Storage.Encoding.encode_int64_key key in
  let value =
    match Storage.Engine.get table_map transaction ~key:encoded_key with
    | None -> Seq.empty
    | Some value_bytes ->
        Seq.return
          (Storage.Row_codec.decode_row kind (encoded_key, value_bytes))
  in
  continue (Term.Relation_value ({ kind; value } : [ `Set | `Bag ] Relation.t))
