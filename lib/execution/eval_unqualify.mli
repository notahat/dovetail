(** The physical [Unqualify] operator.

    Strips the table qualifier from every field of its input, whether that input
    is a relation or a single row. It evaluates its input through the [eval]
    recursor handed in by {!Eval} — the full-term form, since it must handle
    both the relation and row arms. Out of scope: deciding when qualifiers are
    needed; this operator only ever removes them. *)

module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Term = Dovetail_core.Term

val evaluate :
  eval:('perm, 'a) Eval_recurse.eval ->
  Storage.Engine.environment ->
  'perm Storage.Engine.transaction ->
  input:Plan.Physical.t ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~eval environment transaction ~input continue] evaluates [input]
    and hands [continue] the same value under an unqualified kind: a relation
    passes its row sequence through unchanged with a new kind; a row rebuilds
    the [Row.t]. Raises [Failure] naming the colliding bare name if two fields
    would clash after stripping. *)
