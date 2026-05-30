(** The one-row result relation that the create-table and drop-table operators
    report.

    A single [(<verb> : string)] row carrying the affected table's name, where
    [verb] is "created" or "dropped". Mirrors
    {!Plan.Physical.create_table_result_kind} and
    {!Plan.Physical.drop_table_result_kind}; rebuilt here so the evaluator's
    runtime values line up with those module-level result-shape constants
    without an extra dependency. Out of scope: the insert operator's own
    [(insert_count : int64)] result, which has a different shape. *)

module Relation = Dovetail_core.Relation

val relation : verb:string -> string -> [ `Set | `Bag ] Relation.t
(** [relation ~verb table_name] wraps [table_name] as the one-row
    [(<verb> : string)] relation. *)
