module Relation = Dovetail_core.Relation
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term

(* Materialise a [Relation_literal] as a [Relation.t] using the kind declared
   up front. The empty form ([rows = []]) is valid because the kind doesn't
   depend on a first row. *)
let evaluate ~kind ~rows continue =
  let value = rows |> List.to_seq |> Seq.map Array.of_list in
  continue (Term.Relation_value ({ kind; value } : [ `Set | `Bag ] Relation.t))
