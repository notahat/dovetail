module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* Strip the qualifier from every field in [input_row_kind], or fail with a
   user-facing message naming the colliding bare name and both qualified
   spellings when two fields would clash after stripping. The single source of
   truth for the rule is [Row.unqualify_kind]; the wrapper just attaches the
   operator prefix. *)
let unqualify_row_kind input_row_kind =
  match Row.unqualify_kind input_row_kind with
  | Ok stripped_row_kind -> stripped_row_kind
  | Error detail -> failwith (Printf.sprintf "Unqualify: %s" detail)

(* Run [input] and hand [continue] the same value under an unqualified kind.
   A relation input passes its row sequence through unchanged with a new
   kind; a row input rebuilds the [Row.t] with the new kind. Other arms are
   internal invariant violations -- [Unqualify] only sits over a relational
   or row-yielding sub-plan today. *)
let evaluate ~eval environment transaction ~input continue =
  eval environment transaction input (function
    | Term.Relation_value relation ->
        let row_kind = unqualify_row_kind relation.kind.row_kind in
        let kind : Relation.kind =
          { row_kind; refinements = relation.kind.refinements }
        in
        continue
          (Term.Relation_value
             ({ kind; value = relation.value } : [ `Set | `Bag ] Relation.t))
    | Term.Row_value row ->
        let kind = unqualify_row_kind row.kind in
        continue (Term.Row_value ({ kind; value = row.value } : Row.t))
    | Term.Relation_kind _ | Term.Scalar_value _ | Term.Scalar_kind _
    | Term.Row_kind _ | Term.Catalog_value _ | Term.Catalog_kind _ ->
        (* Typecheck has rejected an [Unqualify] over an input that is not
           a relation or a row. *)
        assert false)
