module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* The static row shape [tables] reports: a one-column [name : string] row,
   one row per table in the input catalog. *)
let tables_result_kind : Relation.kind =
  {
    row_kind = [ { name = "name"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

(* Walk [input]'s [Catalog_value] and stream one row per (table_name, _)
   entry as a [`Set]-tagged relation with kind [(name: string)]. The
   non-catalog arms are unreachable: [Plan.Typecheck] rejects a [Tables]
   whose input sits at the wrong rung before [Eval] runs. *)
let evaluate ~eval environment transaction ~input continue =
  eval environment transaction input (function
    | Term.Catalog_value catalog ->
        let row_of_entry (table_name, _) : Row.value =
          [| Scalar.String table_name |]
        in
        let value = List.to_seq catalog.relations |> Seq.map row_of_entry in
        continue
          (Term.Relation_value
             ({ kind = tables_result_kind; value } : [ `Set | `Bag ] Relation.t))
    | Term.Scalar_value _ | Term.Scalar_kind _ | Term.Row_value _
    | Term.Row_kind _ | Term.Relation_value _ | Term.Relation_kind _
    | Term.Catalog_kind _ ->
        (* Typecheck has rejected a [Tables] over a non-catalog input. *)
        assert false)
