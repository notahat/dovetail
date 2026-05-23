(** The unified pipeline-payload carrier.

    A [Term.t] is the rung-aware union of everything that flows through a pipe
    or falls out the end of one. The evaluator's continuation receives a
    [Term.t]; the REPL's renderer dispatches on its arms.

    Today the type has two arms — a relation value and a relation kind. Other
    arms (scalar / row / catalog, on both faces) grow incrementally as later
    work needs them. The [`Set] / [`Bag] phantom on [Relation_value] is the same
    multiplicity tag {!Relation.t} carries; the kind arm has no value to
    classify, so the tag is unconstrained when only the kind arm is in use. *)

type 'tag t =
  | Relation_value of 'tag Relation.t
      (** A relation's value: a kind-tagged stream of rows, produced by ordinary
          pipeline evaluation. *)
  | Relation_kind of Relation.kind
      (** A relation's kind: the shape-and-refinements descriptor a pipeline
          produces when it yields a type rather than rows. *)
  constraint 'tag = [< `Set | `Bag ]

val format : Format.formatter -> 'tag t -> unit
(** [format formatter term] writes [term] to [formatter], dispatching on its
    arm. [Relation_value] renders as a table (via {!Relation.print});
    [Relation_kind] renders in the surface relation-type syntax (via
    {!Relation.format_kind}). *)
