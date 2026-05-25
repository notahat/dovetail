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
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

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
  | Relation_literal of { kind : Relation.kind; rows : Scalar.value list list }
      (** [Relation_literal { kind; rows }] is a relation given directly by its
          contents, with the row kind declared up front. Each row in [rows] is a
          list of values in the order of [kind.row_kind]'s fields. The empty
          form ([rows = []]) is valid because the kind is declared directly, not
          inferred from a first row. *)
  | Insert of { table : string; source : t }
      (** [Insert { table; source }] writes [source]'s rows to [table] and
          yields a one-row relation reporting the affected-row count. Insert
          declares [`Write] in {!required_access}, which is how the REPL knows
          to open a write transaction for any plan that contains it. *)
  | Unqualify of { input : t }
      (** [Unqualify { input }] strips the qualifier from every field of
          [input]'s row kind, leaving the bare names. [input] is either a
          relation (yields a relation with the same rows under the unqualified
          kind) or a row (yields a row under the unqualified kind). Fails at
          eval time -- and at {!Physical.kind_of} time -- when two fields would
          collide on their bare name after stripping. The identity on inputs
          that already have no qualifiers. *)
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
  | Drop_table of { table_name : string }
      (** [Drop_table { table_name }] removes [table_name] from the catalog and
          its storage. A leaf operator with no input. Reports [`Write] from
          {!required_access}. Yields a one-row relation
          [(dropped: string) { (dropped = table_name) }]. *)
  | Create_table_empty of { table_name : string; kind : Relation.kind }
      (** [Create_table_empty { table_name; kind }] creates an empty table named
          [table_name] with the declared [kind]. Carries the resolved
          {!Relation.kind} -- the surface-level type expression has already been
          lowered. A leaf operator with no relation-valued input; reports
          [`Write] from {!required_access}. Yields a one-row relation
          [(created: string) { (created = table_name) }]. *)
  | Create_table_seeded of { table_name : string; source : t }
      (** [Create_table_seeded { table_name; source }] creates [table_name] from
          the row kind of [source] and seeds it with [source]'s rows, both in
          the same write transaction. The target's kind is derived from
          [source]'s kind at evaluation time. Reports [`Write] from
          {!required_access} (and recurses into [source]'s access). Yields a
          one-row relation [(created: string) { (created = table_name) }]. *)
  | Row_literal of { fields : (Row.column_reference * Scalar.value) list }
      (** [Row_literal { fields }] is a pipeline whose source is a literal row,
          with no scan or storage involved. [fields] carries the row's bindings
          in source order; each entry pairs a column reference (qualified
          [qualifier.name] or bare [name]) with its value. The parser rejects
          duplicate qualified-name pairs, so the list is unique. Sits at a
          pipeline's root only; the row's kind is derived eagerly from the
          values' scalar kinds and the references' qualifiers. Reports [`Read]
          from {!required_access}. *)

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
