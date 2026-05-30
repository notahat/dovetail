(** The physical [Create_table_empty] operator.

    Creates a new, empty table from a pre-resolved kind. Out of scope: seeding
    rows — that is [Create_table_seeded]. *)

module Storage = Dovetail_storage
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

val evaluate :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  table_name:string ->
  kind:Relation.kind ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate environment transaction ~table_name ~kind continue] creates
    [table_name] with shape [kind], handing [continue] the one-row
    [(created : string)] result. The static-shape checks live in
    [Plan.Typecheck] and have already run; this runs the catalog "already
    exists" check before any storage mutation, so a name collision leaves
    catalog and storage untouched. [transaction] is widened to a write
    transaction; the caller has routed write plans accordingly. *)
