module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Relation = Dovetail_core.Relation
module Expression = Dovetail_core.Expression
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Stream the input through [eval_relation], then wrap its value seq in a
   [Seq.filter] guarded by the resolved predicate. The kind is unchanged.
   [Expression.resolve] is a closure-builder -- column resolution and kind
   discipline run in [Plan.Typecheck] before we get here. *)
let evaluate ~eval_relation environment transaction ~input ~predicate continue =
  let* (input_relation : [ `Set | `Bag ] Relation.t) =
    eval_relation environment transaction input
  in
  let evaluate_predicate =
    Expression.resolve input_relation.kind.row_kind predicate
  in
  continue
    (Term.Relation_value
       ({
          kind = input_relation.kind;
          value = Seq.filter evaluate_predicate input_relation.value;
        }
         : [ `Set | `Bag ] Relation.t))
