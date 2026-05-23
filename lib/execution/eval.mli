(** Streaming, continuation-passing executor for the physical IR.

    [eval] takes a {!Physical.t} tree and a consumer continuation. It invokes
    the continuation with a {!Relation.t} whose [data] sequence pulls rows
    lazily from whatever cursors the plan opens. The continuation runs inside
    those cursor scopes; once it returns, the cursors are torn down and the
    relation is no longer usable.

    Operators implement their part of the pipeline by nesting continuations:
    each operator opens its inputs through [eval], composes a transformed
    relation in the innermost callback, and hands the result to its own
    [continue]. Linear pipelines (FullScan / Filter / Project) stream end-to-end
    at O(1) memory per cursor; joins still materialise their right input because
    the outer loop re-iterates it. *)

module Relation = Dovetail_core.Relation
module Storage = Dovetail_storage
module Plan = Dovetail_plan

val eval :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  Plan.Physical.t ->
  ([ `Bag ] Relation.t -> 'a) ->
  'a
(** [eval environment transaction plan continue] runs [plan] against the
    database open in [environment], using [transaction] for all reads, and
    invokes [continue] with the resulting relation. The relation's [data]
    sequence must be consumed inside [continue]; using it after [continue]
    returns is undefined behaviour.

    Raises [Failure] if [plan] references a table the catalog has no schema for,
    if a column reference cannot be resolved, or on any other plan-shape or
    schema mismatch surfaced by the operators. Errors are raised eagerly where
    possible (e.g. predicate resolution runs before any rows are pulled), so
    most failure modes surface before [continue] is called. *)

val eval_mutation :
  Storage.Engine.environment ->
  [ `Read | `Write ] Storage.Engine.transaction ->
  Plan.Physical.mutation ->
  (int -> 'a) ->
  'a
(** [eval_mutation environment transaction mutation continue] runs [mutation]
    against the database open in [environment] and invokes [continue] with the
    number of rows it wrote.

    For [Insert { table; source }], the sink evaluates [source] as a relation
    via {!eval} (inside the same write [transaction]), then for each source row
    performs a [Storage.Engine.get] to detect a primary-key collision against an
    existing row, and a [Storage.Engine.put] to write the row otherwise. The
    count handed to [continue] is the number of [put]s performed.

    The continuation shape mirrors {!eval} so the two entry points dispatch
    uniformly at the call site. The affected-row count is itself a plain value
    with no scoped resource attached, but threading it through a continuation
    keeps future mutation outputs (e.g. RETURNING-style row streams) able to
    slot in without a second signature break.

    Raises [Failure] under the same conditions as {!eval}, plus on a primary-key
    collision against an existing row in the target table. A raise aborts the
    in-flight write transaction via the standard exception path of
    {!Storage.Engine.with_write_transaction}, so any earlier writes in the same
    mutation are discarded -- multi-row inserts (once the multi-row literal
    grammar lands) commit all-or-nothing.

    [transaction] is required to be a write transaction at the type level; there
    is no perm-coercion machinery inside the sink. Read-only callers keep using
    {!eval}; the REPL's plan classifier dispatches to the right entry. *)
