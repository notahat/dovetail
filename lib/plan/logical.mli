(** Logical relational-algebra IR.

    The logical IR is the layer between the surface AST and the physical
    operators that {!Eval} executes. Logical operators describe *what* a query
    computes — read these rows, keep these columns, join on this predicate —
    without committing to *how*. {!Translate} lowers logical operators into a
    physical plan that picks an execution strategy.

    Constructor names follow relational-algebra terms (σ → [Restrict], π →
    [Project], × → [CrossProduct]) rather than SQL keywords, leaving room for a
    SQL front end to map its vocabulary onto the same IR. *)

module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression

type t =
  | Scan of { table : string }
      (** [Scan { table }] reads every row of [table]. The logical operator
          carries no execution detail; it's the [Translate] layer's job to pick
          between full-scan, index-scan, and so on. *)
  | Restrict of { input : t; predicate : Expression.t }
      (** [Restrict { input; predicate }] keeps the rows of [input] for which
          [predicate] holds. The constructor name follows the relational-algebra
          term for σ; the executor convention (Filter) takes over once
          {!Translate} has run. *)
  | Project of { input : t; columns : Projection.t }
      (** [Project { input; columns }] narrows [input] to the named [columns],
          in the order given. Mirrors π in the relational algebra. The output
          schema's [primary_key] is empty regardless of whether [columns]
          includes the input's PK; see {!Projection.resolve}. *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] is the cartesian product (×) of the two
          inputs: every (left, right) row pair. The result schema is [left]'s
          fields followed by [right]'s, with qualifiers preserved. The output
          [primary_key] is empty: derived relations don't carry PK information
          at this point in the project. *)
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
      (** [RelationLiteral { columns; rows }] is a relation given directly by
          its contents, with no scan or storage involved. Each row in [rows] is
          a list of values, one per declared column, in column order. The output
          kind is {!Dovetail_core.Relation_literal.kind_of} applied to [columns]
          and the first row.

          The parser currently produces single-row literals only; the IR shape
          leaves room for a future multi-row literal grammar. *)

type mutation =
  | Insert of { table : string; source : t }
      (** A row-writing mutation. [source] is a relation-yielding sub-plan; its
          rows are what get written to [table]. The {!plan} wrapper below sits
          above this type so the REPL can dispatch on plan kind: queries open a
          read transaction and call {!Eval.eval}; mutations open a write
          transaction and call {!Eval.eval_mutation}. Update and delete are not
          yet supported. *)

type plan =
  | Query of t
  | Mutation of mutation
      (** A top-level logical plan: either a relation-yielding {!t} or a
          row-writing {!mutation}. {!Lower.lower} returns this, and the REPL
          uses {!classify} to pick a transaction kind before handing the plan to
          {!Translate.translate}. Mutations don't nest, because {!mutation}'s
          [source] field is a {!t}, not a [plan]. *)

val required_access : t -> [ `Read | `Write ]
(** [required_access plan] walks [plan] and returns the strongest transaction
    permission any operator in the tree needs. Every operator currently in [t]
    is read-only, so the result is always [`Read] today; the walker is the seam
    where future write-capable operators declare their access locally without
    {!classify}'s callers needing to enumerate them. *)

val classify : plan -> [ `Read | `Write ]
(** [classify plan] returns the transaction permission the REPL should open for
    [plan]: [`Read] for a query (delegating to {!required_access} on the inner
    tree), [`Write] for a mutation. The REPL uses this to choose between
    {!Dovetail_storage.Engine.with_read_transaction} and
    {!Dovetail_storage.Engine.with_write_transaction} before translation, so a
    read-only query isn't unnecessarily serialised against LMDB's writer lock.
*)

val format : Format.formatter -> t -> unit
(** [format formatter plan] writes [plan] to [formatter] as an indented tree,
    one operator per line, with each operator's inputs indented two spaces
    further than the operator itself. Operators render their name followed by
    their distinguishing parameters in parentheses ([Scan(table)],
    [Restrict(predicate)], [Project(columns)],
    [RelationLiteral(columns=..., rows=N)]); [CrossProduct] renders bare for the
    same reason its physical counterpart does. The output is for EXPLAIN-style
    debug printing -- the [--show-logical] flag on the binary is the primary
    consumer. *)

val format_plan : Format.formatter -> plan -> unit
(** [format_plan formatter plan] writes [plan] to [formatter]. A {!Query}
    renders exactly as {!format} would render its inner relation tree -- no
    wrapping header. A {!Mutation} prints its operator header ([Insert(table)])
    on one line with the [source] indented one level beneath, matching the
    per-operator indentation convention {!format} uses. *)
