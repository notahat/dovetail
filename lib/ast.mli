(** Surface AST for the relational-algebra query language.

    The AST is the structure produced by the {!Parser} from a textual query. It
    mirrors the surface syntax: every node corresponds to something the user
    typed, and nothing more. {!Lower} converts the AST into a logical plan,
    where the operators take their meaning from algebra rather than syntax.

    Slice 1 introduced [Relation_name] (bare identifiers); slice 2 adds
    [Restrict] (the `restrict` pipeline step). Operators (projection, joins) and
    richer literals arrive as later slices introduce them. *)

type t =
  | Relation_name of string
      (** [Relation_name name] is a reference to the base relation called [name]
          — the surface syntax is just the bare identifier. *)
  | Restrict of { input : t; predicate : Predicate.t }
      (** [Restrict { input; predicate }] is the surface form
          [input | restrict <predicate>]. The constructor name follows the
          relational-algebra term (σ); SQL's `SELECT` is intentionally avoided
          because it names a different operation. *)
  | Project of { input : t; columns : Projection.t }
      (** [Project { input; columns }] is the surface form
          [input | project <columns>]. The constructor name follows the
          relational-algebra term (π). *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] is the surface form
          [left | cross right]. The result has one row for every pair drawn from
          [left] and [right]; its schema is [left]'s fields followed by
          [right]'s, with each field carrying the qualifier it had on the way
          in. *)
  | Join of { left : t; right : t; predicate : Predicate.t }
      (** [Join { left; right; predicate }] is the surface form
          [left | join right on <predicate>]. Sugar for cross product followed
          by a restriction: [Lower] desugars it to
          [Logical.Restrict (Logical.CrossProduct { left; right }, predicate)],
          and {!Translate} folds that shape into a single
          [Physical.NestedLoopJoin]. The schema rule is the same as
          [CrossProduct] -- both inputs' fields, each retaining its qualifier --
          so a [predicate] like [users.id = orders.user_id] resolves
          unambiguously across the combined schema. *)
