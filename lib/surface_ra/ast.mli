(** Surface AST for the relational-algebra query language.

    The AST is the structure produced by the {!Parser} from a textual query. It
    mirrors the surface syntax: every node corresponds to something the user
    typed, and nothing more. {!Lower} converts the AST into a logical plan,
    where the operators take their meaning from algebra rather than syntax.

    A top-level {!program} is one of two universes: a {!Pipeline} (the
    relational-pipeline universe; every operator is a node in {!t} and produces
    a relation, including write operators like {!Insert}), or a {!Ddl} (a
    data-definition statement such as [:list tables]). The two universes meet
    only at this top-level wrapper: DDL doesn't pass through {!Lower} /
    {!Translate} / {!Physical} / {!Eval}, so those layers see only the {!t} that
    lives inside {!Pipeline}. *)

module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row
module Ddl = Dovetail_ddl
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

type program =
  | Pipeline of t
      (** [Pipeline plan] is the relational-pipeline universe: every non-DDL
          input the surface language accepts. Threaded through {!Lower.lower},
          {!Translate.translate}, and {!Eval.eval}. *)
  | Ddl of Ddl.Statement.t
      (** [Ddl statement] is the data-definition universe, marked at the surface
          by the leading [:] sigil. {!Lower}, {!Translate}, and the physical
          layers know nothing of DDL; the REPL hands the statement straight to
          {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write}. *)
