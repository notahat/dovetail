module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Stream the input through [eval_relation], then wrap its value seq in a
   [Seq.map] that projects each row to the requested columns.
   [Projection.resolve] is a closure-builder -- column resolution and
   duplicate-column detection run in [Plan.Typecheck] before we get here. *)
let evaluate ~eval_relation environment transaction ~input ~columns continue =
  let* (input_relation : [ `Set | `Bag ] Relation.t) =
    eval_relation environment transaction input
  in
  let projected_kind, project_row =
    Plan.Projection.resolve input_relation.kind columns
  in
  continue
    (Term.Relation_value
       ({
          kind = projected_kind;
          value = Seq.map project_row input_relation.value;
        }
         : [ `Set | `Bag ] Relation.t))
