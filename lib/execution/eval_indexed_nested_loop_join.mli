(** The physical [IndexedNestedLoopJoin] operator.

    Streams the outer sub-plan and probes the inner table's storage once per
    outer row, joining on the inner's primary key. The outer sub-plan is
    evaluated through the [eval_relation] recursor handed in by {!Eval}. Out of
    scope: joins not keyed on the inner's primary key — those are
    [NestedLoopJoin]. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Row = Dovetail_core.Row
module Term = Dovetail_core.Term

val evaluate :
  eval_relation:('perm, 'a) Eval_recurse.eval_relation ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  outer:Plan.Physical.t ->
  inner_table:string ->
  outer_key_column:Row.column_reference ->
  inner_position:[ `Left | `Right ] ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval_relation environment transaction ~outer ~inner_table
     ~outer_key_column ~inner_position continue] streams [outer] and probes
    [inner_table] by each outer row's value at [outer_key_column]. A hit yields
    one combined row; a miss drops the outer row. [inner_position] orders the
    combined fields: [`Left] inner-first, [`Right] outer-first. Raises [Failure]
    if [outer_key_column] doesn't resolve or isn't [Int64]. *)
