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
  | Restrict of { input : t; predicate : Expression.t }
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
  | Join of { left : t; right : t; predicate : Expression.t }
      (** [Join { left; right; predicate }] is the surface form
          [left | join right on <predicate>]. Sugar for cross product followed
          by a restriction: [Lower] desugars it to
          [Logical.Restrict (Logical.CrossProduct { left; right }, predicate)],
          and {!Translate} folds that shape into a single
          [Physical.NestedLoopJoin]. The schema rule is the same as
          [CrossProduct] -- both inputs' fields, each retaining its qualifier --
          so a [predicate] like [users.id = orders.user_id] resolves
          unambiguously across the combined schema. *)
  | RelationLiteral of { columns : string list; rows : Value.t list list }
      (** [RelationLiteral { columns; rows }] is the surface form
          [{col: val, col: val, ...}] -- a relation whose contents the user gave
          directly, instead of a reference to a stored table. Slice 11's parser
          accepts the single-row named-pair form only, so [rows] always has
          length one; the IR shape leaves room for a future multi-row literal
          grammar.

          Column names are bare identifiers (the parser rejects qualified keys)
          and must be unique within the literal (the parser rejects duplicates).
          Each row in [rows] has the same length as [columns], and the values
          appear in column order. *)
