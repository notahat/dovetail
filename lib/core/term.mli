(** The unified pipeline-payload carrier.

    A [Term.t] is the rung-aware union of everything that flows through a pipe
    or falls out the end of one. The evaluator's continuation receives a
    [Term.t]; the REPL's renderer dispatches on its arms.

    The type covers the four rungs the language exposes — scalar, row, relation,
    and catalog — on both faces: a [_value] arm for a runtime value and a
    [_kind] arm for the static shape that classifies such a value. The [`Set] /
    [`Bag] phantom on [Relation_value] is the same multiplicity tag
    {!Relation.t} carries; the other arms have no multiplicity to classify, so
    the tag is unconstrained when those arms are in use. *)

type 'tag t =
  | Scalar_value of Scalar.value
      (** A single value: an [Int64], [String], or [Bool] payload produced by a
          scalar-source pipeline. *)
  | Scalar_kind of Scalar.kind
      (** A scalar kind: the static type that classifies a scalar value. *)
  | Row_value of Row.t
      (** A row's value, paired with the {!Row.kind} that describes its shape so
          the row can be rendered without separate plumbing. *)
  | Row_kind of Row.kind
      (** A row's kind: the ordered field declarations that classify a row
          value. *)
  | Relation_value of 'tag Relation.t
      (** A relation's value: a kind-tagged stream of rows, produced by ordinary
          pipeline evaluation. *)
  | Relation_kind of Relation.kind
      (** A relation's kind: the shape-and-refinements descriptor a pipeline
          produces when it yields a type rather than rows. *)
  | Catalog_value of Catalog.value
      (** A catalog's value: the database's tables and their rows, produced by
          the bare [catalog] source. Carries no [`Set] / [`Bag] phantom because
          {!Catalog.value} pins each entry to [`Set] internally. *)
  | Catalog_kind of Catalog.kind
      (** A catalog's kind: the per-table relation kinds, produced when the
          catalog rung yields a type rather than data. *)
  constraint 'tag = [< `Set | `Bag ]

val format : Format.formatter -> 'tag t -> unit
(** [format formatter term] writes [term] to [formatter], dispatching on its
    arm. [Scalar_value] renders via {!Scalar.format}; [Scalar_kind] via
    {!Scalar.format_kind}; [Row_value] via {!Row.format}; [Row_kind] via
    {!Row.format_kind}; [Relation_value] in the canonical relation-literal
    syntax (via {!Relation.format}); [Relation_kind] in the surface
    relation-type syntax (via {!Relation.format_kind}). The [Catalog_value] and
    [Catalog_kind] arms currently emit a placeholder rendering; a real
    catalog-literal renderer arrives in a follow-up step. *)
