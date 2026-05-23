(** Streaming, continuation-passing executor for the physical IR.

    [eval] takes a {!Physical.t} tree and a consumer continuation. It invokes
    the continuation with a {!Relation.t} whose [value] sequence pulls rows
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
    invokes [continue] with the resulting relation. The relation's [value]
    sequence must be consumed inside [continue]; using it after [continue]
    returns is undefined behaviour.

    [Insert { table; source }] is just another operator in [plan]: the sink
    evaluates [source] via the same [eval], then for each source row probes the
    target's storage for a primary-key collision and writes the row, and hands
    [continue] a one-row relation with kind [(insert_count : int64)] and value
    equal to the number of writes performed. Insert requires the [transaction]
    to be a write transaction; callers route to the right transaction kind via
    {!Logical.required_access} before calling [eval].

    Raises [Failure] if [plan] references a table the catalog has no schema for,
    if a column reference cannot be resolved, on a primary-key collision when an
    [Insert] is reached, or on any other plan-shape or schema mismatch surfaced
    by the operators. Errors are raised eagerly where possible (e.g. predicate
    resolution runs before any rows are pulled), so most failure modes surface
    before [continue] is called. A raise inside an [Insert] aborts the in-flight
    write transaction via the standard exception path of
    {!Storage.Engine.with_write_transaction}, so any earlier writes are
    discarded -- multi-row inserts commit all-or-nothing. *)
