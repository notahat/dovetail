module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term
module Storage = Dovetail_storage

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Open the cursor for the duration of [continue] and hand it a relation
   whose rows are pulled lazily from the live cursor. *)
let evaluate environment transaction table_name continue =
  let* relation =
    Table_access.build_table_relation environment transaction ~table_name
  in
  continue (Term.Relation_value (relation : [ `Set | `Bag ] Relation.t))
