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
  | Insert of { table : string; source : t }
      (** [Insert { table; source }] writes [source]'s rows to [table] and
          yields a one-row relation reporting the affected-row count. Insert
          declares [`Write] in {!required_access}, which is how the REPL knows
          to open a write transaction for any plan that contains it. *)
  | Type_op of { input : t }
      (** [Type_op { input }] yields [input]'s relation type rather than its
          rows. {!Eval} reads the static {!Relation.kind} via
          {!Physical.kind_of} without opening any cursors. The node sits at the
          root of a pipeline only — [Lower] rejects a nested
          [Type_op { input = Type_op _ }] with a user-facing error.
          {!required_access} recurses into [input], so a [Type_op] over a
          read-only sub-plan stays read-only. *)
  | Scalar_literal of Scalar.value
      (** [Scalar_literal value] is a pipeline whose source is the literal
          [value] itself, with no scan or storage involved. Sits at a pipeline's
          root only; the relational operators (Restrict, Project, …) expect
          relation-typed inputs, so a scalar source flows through rungs that
          match it ([Type_op] today; row-level operators in later slices).
          Reports [`Read] from {!required_access}. *)
  | Row_literal of { fields : (string * Scalar.value) list }
      (** [Row_literal { fields }] is a pipeline whose source is a literal row,
          with no scan or storage involved. [fields] carries the row's bindings
          in source order; the parser rejects duplicate field names so the list
          is unique. Sits at a pipeline's root only; the row's kind is derived
          eagerly from the values' scalar kinds. Reports [`Read] from
          {!required_access}. *)

val required_access : t -> [ `Read | `Write ]
(** [required_access plan] walks [plan] and returns the strongest transaction
    permission any operator in the tree needs. The REPL uses the result to
    choose between {!Dovetail_storage.Engine.with_read_transaction} and
    {!Dovetail_storage.Engine.with_write_transaction} before translation, so a
    read-only query isn't unnecessarily serialised against LMDB's writer lock.
*)

val format : Format.formatter -> t -> unit
(** [format formatter plan] writes [plan] to [formatter] as an indented tree,
    one operator per line, with each operator's inputs indented two spaces
    further than the operator itself. Operators render their name followed by
    their distinguishing parameters in parentheses ([Scan(table)],
    [Restrict(predicate)], [Project(columns)],
    [RelationLiteral(columns=..., rows=N)], [Insert(table)]); [CrossProduct]
    renders bare for the same reason its physical counterpart does. The output
    is for EXPLAIN-style debug printing -- the [--show-logical] flag on the
    binary is the primary consumer. *)
