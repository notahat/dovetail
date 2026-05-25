(** Surface AST for the relational-algebra query language.

    The AST is the structure produced by the {!Parser} from a textual query. It
    mirrors the surface syntax: every node corresponds to something the user
    typed, and nothing more. {!Lower} converts the AST into a logical plan,
    where the operators take their meaning from algebra rather than syntax.

    Every top-level input is a relational pipeline: an {!t} whose operators each
    produce a relation, including write operators like {!Insert}. *)

module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row
module Plan = Dovetail_plan

type type_field = {
  qualifier : string option;
  name : string;
  kind : Scalar.kind;
}
(** A single binding inside a row- or relation-type expression: a field name
    paired with the scalar kind it carries. The surface syntax is [name: kind]
    for an unqualified field and [qualifier.name: kind] for a qualified one;
    {!qualifier} records the dotted prefix when present and is [None] otherwise.
*)

type type_expression = {
  fields : type_field list;
  refinements : Relation.refinement list;
}
(** A parenthesised type expression as written at the surface. Two surface forms
    map onto this one node:

    - A {b row-type expression} ([(id: int64, name: string)]) parses with
      [refinements = []]; the row-type parser rejects any refinement clause.
    - A {b relation-type expression}
      ([(id: int64, name: string, primary key (id))]) parses with the same
      fields plus zero or more refinement clauses.

    The empty form [()] parses as [{ fields = []; refinements = [] }] in either
    context. *)

type t =
  | Relation_name of string
      (** [Relation_name name] is a reference to the base relation called [name]
          — the surface syntax is just the bare identifier. *)
  | Restrict of { input : t; predicate : Expression.t }
      (** [Restrict { input; predicate }] is the surface form
          [input | restrict <predicate>]. The constructor name follows the
          relational-algebra term (σ); SQL's `SELECT` is intentionally avoided
          because it names a different operation. *)
  | Project of { input : t; columns : Plan.Projection.t }
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
  | Insert of { table : string; source : t }
      (** [Insert { table; source }] is the surface form
          [source | insert into <table>]. [source] is the upstream relation
          whose rows get written; [table] names the target. Insert produces a
          one-row relation reporting the affected-row count, so it sits in {!t}
          alongside the relation-yielding operators rather than in a separate
          mutation universe. The grammar still admits the sink only in terminal
          position, but the structural guarantee no longer comes from the type.
      *)
  | Unqualify of { input : t }
      (** [Unqualify { input }] is the surface form [input | unqualify]. Drops
          the qualifier from every field of [input]'s row kind so downstream
          stages see bare names. A collision on the resulting bare names is
          rejected at eval time. The operator accepts either a relation or a row
          on the left. *)
  | Type of { input : t }
      (** [Type { input }] is the surface form [input | type]. Evaluation yields
          [input]'s relation type rather than its rows — no cursors open, no
          rows pulled. The constructor sits at the root of a pipeline only;
          {!Lower} rejects [input | type | type] because the second [type]'s
          input is a type, not a relation. The parser does not yet produce this
          node — until it does, the only way to reach it is by building one
          directly. *)
  | Scalar_literal of Scalar.value
      (** [Scalar_literal value] is the surface form of a bare scalar at the
          head of a pipeline: [42], ["hello"], [true]. The pipeline's source is
          the value itself; evaluation hands the value down the pipe as a
          {!Term.Scalar_value}, and [| type] over a scalar literal yields the
          corresponding {!Scalar.kind}. *)
  | Row_literal of (Row.column_reference * Scalar.value) list
      (** [Row_literal fields] is the surface form of a bare row at the head of
          a pipeline: [(id = 1, name = "alice")] parses as a list of two fields
          whose column references are unqualified. A qualified spelling such as
          [(users.id = 1)] parses with [qualifier = Some "users"] on the
          reference. The empty row [()] parses as [Row_literal []]. Fields are
          in source order; the parser rejects duplicate qualified-name pairs.
          Evaluation hands the row down the pipe as a {!Term.Row_value}, and
          [| type] over a row literal yields the corresponding {!Row.kind}. *)
  | Drop_table of { table_name : string }
      (** [Drop_table { table_name }] is the surface form [drop table <name>]. A
          leaf source -- nothing sits at pipeline-source position to its left.
          Yields a one-row [(dropped : string)] relation reporting the dropped
          table's name. *)
  | Create_table_empty of {
      table_name : string;
      type_expression : type_expression;
    }
      (** [Create_table_empty { table_name; type_expression }] is the surface
          form [<type-expression> | create table <name>] -- creates an empty
          table whose declared kind is the carried [type_expression]. {!Lower}
          calls {!lower_relation_type} to resolve the type expression to a
          {!Relation.kind}. Yields a one-row [(created : string)] relation. *)
  | Create_table_seeded of { table_name : string; source : t }
      (** [Create_table_seeded { table_name; source }] is the surface form
          [<value-pipeline> | create table <name>] -- creates [table_name] from
          [source]'s row kind and seeds it with [source]'s rows. {!Lower}
          recurses into [source]; the target kind is derived from [source]'s
          kind at eval time. Yields a one-row [(created : string)] relation. *)
  | Relation_literal of {
      kind : Relation.kind;
      rows : (Row.column_reference * Scalar.value) list list;
    }
      (** [Relation_literal { kind; rows }] is the surface form
          [relation (id: int64, name: string) { (id = 1, name = "alice"), ... }]
          — a relation whose type is declared up front and whose rows are
          self-describing row literals. The empty form [relation (...) {}]
          parses with [rows = []]. Field names inside each row come straight
          from the surface; {!Lower} checks each row against [kind] and reorders
          the values to [kind]'s field order, then emits a
          {!Plan.Logical.Relation_literal}. *)
  | Catalog_source
      (** [Catalog_source] is the surface form of the bare [catalog] keyword at
          pipeline-source position. It yields the database's catalog as a
          [Term.Catalog_value], whose entries are every table's name paired with
          its rows. {!Lower} emits a logical [Catalog_source] node; the
          evaluator opens a per-table cursor lazily for each entry, scoped to
          the read transaction. *)
  | Tables of { input : t }
      (** [Tables { input }] is the surface form [input | tables]. Takes a
          catalog value on the left and yields a one-column [(name: string)]
          relation, one row per table in [input], in the catalog's cursor order.
          A user-facing error fires at eval time if [input] is not a catalog. *)
