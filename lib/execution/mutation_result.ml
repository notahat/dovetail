module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation

(* The static row shape that drop table and create table report: a
   one-column [(<verb> : string)] row carrying the affected table's
   name. *)
let mutation_result_kind ~verb : Relation.kind =
  {
    row_kind = [ { name = verb; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

(* Wrap [table_name] as the one-row [(<verb> : string)] relation a
   create / drop operator hands its continuation. *)
let relation ~verb table_name : [ `Set | `Bag ] Relation.t =
  {
    kind = mutation_result_kind ~verb;
    value = Seq.return [| Scalar.String table_name |];
  }
