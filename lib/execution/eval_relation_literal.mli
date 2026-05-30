(** The physical [Relation_literal] operator.

    Materialises an inline relation from a declared kind and a list of rows. Out
    of scope: deriving the kind from the rows — the kind is declared up front,
    which is what lets the empty relation carry a shape. *)

module Relation = Dovetail_core.Relation
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term

val evaluate :
  kind:Relation.kind ->
  rows:Scalar.value list list ->
  ([ `Set | `Bag ] Term.t -> 'a) ->
  'a
(** [evaluate ~kind ~rows continue] hands [continue] a [Term.Relation_value]
    with the declared [kind] and one row per entry in [rows]. The empty form
    ([rows = []]) is valid because the kind doesn't depend on a first row. *)
