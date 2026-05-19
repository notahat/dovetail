(** Surface AST for the relational-algebra query language.

    The AST is the structure produced by the {!Parser} from a textual query. It
    mirrors the surface syntax: every node corresponds to something the user
    typed, and nothing more. {!Lower} converts the AST into a logical plan,
    where the operators take their meaning from algebra rather than syntax.

    A top-level {!program} is one of two universes: a {!Pipeline} (a relation
    pipeline -- query or mutation), or a {!Ddl} (a data-definition statement
    such as [:list tables]). The {!Pipeline} arm carries an {!plan}, which is
    itself either a {!Query} or a {!Mutation}; the {!Ddl} arm carries a
    {!Ddl.Statement.t}. The two universes meet only at this top-level wrapper:
    DDL doesn't pass through {!Lower} / {!Translate} / {!Physical} / {!Eval}, so
    those layers see only the {!plan} that lives inside {!Pipeline}.

    The inner {!plan} wrapper enforces "a sink terminates a pipeline"
    structurally: a mutation can only appear at the top of a pipeline, and its
    source field is a {!t}, not a {!plan}, so sinks cannot nest. *)

module Value = Dovetail_core.Value
module Expression = Dovetail_core.Expression
module Ddl = Dovetail_ddl
module Plan = Dovetail_plan

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

type mutation =
  | Insert of { table : string; source : t }
      (** [Insert { table; source }] is the surface form
          [source | insert into <table>]. [source] is the upstream relation
          whose rows get written; [table] names the target. The constructor name
          follows the SQL verb the user typed. *)

type plan =
  | Query of t
      (** [Query relation] is a pipeline that produces rows: every operator
          chain that doesn't end in a sink. *)
  | Mutation of mutation
      (** [Mutation mutation] is a pipeline that ends in a sink. The wrapper
          enforces "a sink terminates a pipeline" in the type system:
          {!mutation}'s [source] field is a {!t}, so a sink cannot appear
          anywhere except at the top of a {!plan}, and cannot nest.

          {!Lower.lower} returns the same wrapper shape at the Logical layer,
          and {!Translate.translate} carries it through to {!Physical.plan}. *)

type program =
  | Pipeline of plan
      (** [Pipeline plan] is the relational pipeline universe: every input the
          surface language has accepted up to slice 11. Threaded through
          {!Lower.lower}, {!Translate.translate}, and {!Eval.eval} or
          {!Eval.eval_mutation} as appropriate. *)
  | Ddl of Ddl.Statement.t
      (** [Ddl statement] is the data-definition universe, marked at the surface
          by the leading [:] sigil. {!Lower}, {!Translate}, and the physical
          layers know nothing of DDL; the REPL hands the statement straight to
          {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write}. *)
