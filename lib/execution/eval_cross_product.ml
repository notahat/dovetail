module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Sequence the left scope and then the right scope via [let*]; the body
   below runs inside both. The right side is materialised via [List.of_seq]
   because the outer loop over left rows re-iterates it -- a one-shot
   streaming seq can't be replayed, and streaming both sides would require
   a different join algorithm (hash, merge). *)
let evaluate ~eval_relation environment transaction ~left ~right continue =
  let* (left_relation : [ `Set | `Bag ] Relation.t) =
    eval_relation environment transaction left
  in
  let* (right_relation : [ `Set | `Bag ] Relation.t) =
    eval_relation environment transaction right
  in
  let right_rows = List.of_seq right_relation.value in
  let combined_kind : Relation.kind =
    {
      row_kind = left_relation.kind.row_kind @ right_relation.kind.row_kind;
      refinements = [];
    }
  in
  let combined_value =
    Seq.flat_map
      (fun left_row ->
        List.to_seq right_rows
        |> Seq.map (fun right_row -> Array.append left_row right_row))
      left_relation.value
  in
  continue
    (Term.Relation_value
       ({ kind = combined_kind; value = combined_value }
         : [ `Set | `Bag ] Relation.t))
