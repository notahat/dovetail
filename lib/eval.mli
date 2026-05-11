(** Volcano-style executor for the physical IR.

    [eval] takes a {!Physical.t} tree and produces a {!Relation.t} whose
    [tuples] sequence yields rows lazily. Each operator is implemented by a
    single function that wires its inputs into a [Seq.t] and threads the
    transaction through.

    Slice 1 introduced {!Physical.FullScan}; slice 2 adds {!Physical.Filter}.
    Further operators are added as later slices introduce them. *)

val eval :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Physical.t ->
  [ `Bag ] Relation.t
(** [eval environment transaction plan] executes [plan] against the database
    open in [environment], using [transaction] for all reads. The returned
    relation's [tuples] sequence must be consumed before [transaction]'s
    callback returns.

    Raises [Failure] if [plan] references a table the catalog has no schema for,
    or if a feature is required that slice 1 does not yet implement (e.g. a
    non-[int64] or composite primary key). *)

val eval_cps :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Physical.t ->
  ([ `Bag ] Relation.t -> 'a) ->
  'a
(** Exploratory CPS-shaped counterpart to {!eval}. Runs [plan] and invokes the
    continuation with the resulting relation; the continuation runs inside
    whatever cursor and resource scopes the plan opens, so the relation's
    [tuples] sequence may be streamed directly from a live cursor rather than
    eagerly materialised.

    During the conversion to a streaming executor, this entry point delegates
    operator-by-operator to {!eval}; the parity tests guarantee identical
    behaviour. Once every operator is converted, {!eval} is removed and this
    becomes the only entry point. *)
