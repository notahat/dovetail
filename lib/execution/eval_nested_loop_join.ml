module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Relation = Dovetail_core.Relation
module Expression = Dovetail_core.Expression
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Same shape as [Eval_cross_product] -- left and right sequenced via
   [let*], right side materialised -- with the predicate resolved against
   the combined row kind and evaluated per (left, right) pair before the
   combined row is emitted. *)
let evaluate ~eval_relation environment transaction ~left ~right ~predicate
    continue =
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
  let evaluate_predicate =
    Expression.resolve combined_kind.row_kind predicate
  in
  let combined_value =
    Seq.flat_map
      (fun left_row ->
        List.to_seq right_rows
        |> Seq.filter_map (fun right_row ->
            let combined = Array.append left_row right_row in
            if evaluate_predicate combined then Some combined else None))
      left_relation.value
  in
  continue
    (Term.Relation_value
       ({ kind = combined_kind; value = combined_value }
         : [ `Set | `Bag ] Relation.t))
