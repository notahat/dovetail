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
