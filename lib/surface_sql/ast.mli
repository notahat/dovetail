(** Surface AST for the SQL query language.

    The AST is the structure produced by the {!Parser} from a textual SQL
    statement. It mirrors the surface syntax: every node corresponds to
    something the user typed, and nothing more. {!Lower} converts the AST into a
    logical plan, where the operators take their meaning from relational algebra
    rather than SQL keywords.

    This is the SQL surface's own AST, kept deliberately separate from the
    relational-algebra surface's AST. The two surfaces share only [core] and
    [plan]; the small amount of structural overlap (an expression sublanguage,
    eventually) is duplicated rather than shared until a third surface or real
    drift makes extraction pay. *)

type select_list =
  | All
      (** The [*] select list: keep every column of the FROM relation, in its
          natural order. A column-list form lands in a later slice. *)

type t =
  | Select of { select_list : select_list; from : string }
      (** [Select { select_list; from }] is the surface form
          [SELECT <select_list> FROM <from>]. [from] is the bare table name as
          written; qualified names and multiple tables arrive with joins. A
          [WHERE] clause arrives in a later slice. *)
