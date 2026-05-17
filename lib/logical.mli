(** Logical relational-algebra IR.

    The logical IR is the layer between the surface AST and the physical
    operators that {!Eval} executes. Logical operators describe *what* a query
    computes — read these rows, keep these columns, join on this predicate —
    without committing to *how*. {!Translate} lowers logical operators into a
    physical plan that picks an execution strategy.

    Constructor names follow relational-algebra terms (σ → [Restrict], π →
    [Project], × → [CrossProduct]) rather than SQL keywords, leaving room for a
    SQL front end to map its vocabulary onto the same IR. *)

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
          inputs: every (left, right) tuple pair. The result schema is [left]'s
          fields followed by [right]'s, with qualifiers preserved. The output
          [primary_key] is empty: derived relations don't carry PK information
          at this point in the project. *)
  | RelationLiteral of { columns : string list; rows : Value.t list list }
      (** [RelationLiteral { columns; rows }] is a relation given directly by
          its contents, with no scan or storage involved. Each row in [rows] is
          a list of values, one per declared column, in column order. The output
          schema is {!Relation_literal.schema_of} applied to [columns] and the
          first row.

          Slice 11's parser produces single-row literals only; the IR shape
          leaves room for a future multi-row literal grammar. *)

type mutation =
  | Insert of { table : string; source : t }
      (** A row-writing mutation. [source] is a relation-yielding sub-plan; its
          rows are what get written to [table]. The {!plan} wrapper below sits
          above this type so the REPL can dispatch on plan kind: queries open a
          read transaction and call {!Eval.eval}; mutations open a write
          transaction and call {!Eval.eval_mutation}. Update and delete are
          deferred to slice 12. *)

type plan =
  | Query of t
  | Mutation of mutation
      (** A top-level logical plan: either a relation-yielding {!t} or a
          row-writing {!mutation}. {!Lower.lower} returns this, and the REPL
          uses {!classify} to pick a transaction kind before handing the plan to
          {!Translate.translate}. Mutations don't nest, because {!mutation}'s
          [source] field is a {!t}, not a [plan]. *)

val classify : plan -> [ `Read | `Write ]
(** [classify plan] returns the transaction permission the REPL should open for
    [plan]: [`Read] for a query, [`Write] for a mutation. The wrapper
    constructor is the only thing inspected -- the inner relation tree or
    mutation isn't walked. The REPL uses this to choose between
    {!Storage.with_read_transaction} and {!Storage.with_write_transaction}
    before translation, so a read-only query isn't unnecessarily serialised
    against LMDB's writer lock. *)
