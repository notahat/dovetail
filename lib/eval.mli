(** Streaming, continuation-passing executor for the physical IR.

    [eval] takes a {!Physical.t} tree and a consumer continuation. It invokes
    the continuation with a {!Relation.t} whose [tuples] sequence pulls rows
    lazily from whatever cursors the plan opens. The continuation runs inside
    those cursor scopes; once it returns, the cursors are torn down and the
    relation is no longer usable.

    Operators implement their part of the pipeline by nesting continuations:
    each operator opens its inputs through [eval], composes a transformed
    relation in the innermost callback, and hands the result to its own
    [continue]. Linear pipelines (FullScan / Filter / Project) stream end-to-end
    at O(1) memory per cursor; joins still materialise their right input because
    the outer loop re-iterates it. *)

val eval :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Physical.t ->
  ([ `Bag ] Relation.t -> 'a) ->
  'a
(** [eval environment transaction plan continue] runs [plan] against the
    database open in [environment], using [transaction] for all reads, and
    invokes [continue] with the resulting relation. The relation's [tuples]
    sequence must be consumed inside [continue]; using it after [continue]
    returns is undefined behaviour.

    Raises [Failure] if [plan] references a table the catalog has no schema for,
    if a column reference cannot be resolved, or on any other plan-shape or
    schema mismatch surfaced by the operators. Errors are raised eagerly where
    possible (e.g. predicate resolution runs before any tuples are pulled), so
    most failure modes surface before [continue] is called. *)
