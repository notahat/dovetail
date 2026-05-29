(** Surface AST for the relational-algebra query language.

    The AST is the structure produced by the {!Parser} from a textual query. It
    mirrors the surface syntax: every node corresponds to something the user
    typed, and nothing more. {!Lower} converts the AST into a logical plan,
    where the operators take their meaning from algebra rather than syntax.

    Every top-level input is a relational pipeline: an {!t} whose operators each
    produce a relation, including write operators like {!Insert}. *)

(* [Scalar] is the only module from outside [surface_ra] that the AST
   references. Scalar kinds and values are primitive tags and payloads carried
   verbatim from the surface; every other semantic type lives on the far side
   of {!Lower} and the AST has no business naming them here. *)
module Scalar = Dovetail_core.Scalar

type column_reference = { qualifier : string option; name : string }
(** A reference to a column by name, with an optional dotted qualifier. The
    surface syntax is the bare identifier [name] when unqualified, and the
    [qualifier.name] form when qualified. *)

val format_column_reference : column_reference -> string
(** Render a [column_reference] in its source form: dotted [qualifier.name] when
    qualified, bare [name] otherwise. *)

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

type refinement =
  | Primary_key of column_reference list
      (** A constraint clause attached to a relation type. Today only
          [Primary_key columns] exists; it carries the AST-side
          {!column_reference} so refinements share the column vocabulary used
          everywhere else in the AST. The surface grammar emits only unqualified
          columns inside a [primary key (...)] clause; the qualifier slot is
          present for uniformity but is always [None] in parsed input. *)

type type_expression = {
  fields : type_field list;
  refinements : refinement list;
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

type projection = column_reference list
(** A [project] step's column list: the ordered references to keep from the
    input relation. Order is preserved through lowering. *)

type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual
      (** The six binary comparison operators the parser admits inside a
          {!Compare} expression. *)

(** The surface expression sublanguage used inside {!Restrict} and {!Join}
    predicates. {!Column} carries an AST-side {!column_reference}; resolution
    against a row schema happens after lowering. *)
type expression =
  | Literal of Scalar.value
      (** A literal scalar value as written in the source. *)
  | Column of column_reference
      (** A reference to a column by name (bare or qualified). *)
  | Compare of { left : expression; op : comparison_op; right : expression }
      (** A binary comparison between two sub-expressions. *)
  | And of expression * expression
      (** Logical conjunction, left-associative in the surface grammar. *)
  | Or of expression * expression
      (** Logical disjunction, left-associative in the surface grammar. *)
  | Not of expression  (** Logical negation. *)

type t =
  | Relation_name of string
      (** [Relation_name name] is a reference to the base relation called [name]
          — the surface syntax is just the bare identifier. *)
  | Restrict of { input : t; predicate : expression }
      (** [Restrict { input; predicate }] is the surface form
          [input | restrict <predicate>]. The constructor name follows the
          relational-algebra term (σ); SQL's `SELECT` is intentionally avoided
          because it names a different operation. *)
  | Project of { input : t; columns : projection }
      (** [Project { input; columns }] is the surface form
          [input | project <columns>]. The constructor name follows the
          relational-algebra term (π). *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] is the surface form
          [left | cross right]. The result has one row for every pair drawn from
          [left] and [right]; its schema is [left]'s fields followed by
          [right]'s, with each field carrying the qualifier it had on the way
          in. *)
  | Join of { left : t; right : t; predicate : expression }
      (** [Join { left; right; predicate }] is the surface form
          [left | join right on <predicate>]. Sugar for a cross product followed
          by a restriction on the same predicate. The schema rule is the same as
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
          [input]'s type rather than its value — no cursors open, no rows
          pulled. [input] can be a scalar, row, relation, or catalog; downstream
          type-checking rejects [input | type | type] because the second
          [type]'s input is already a type. *)
  | Scalar_literal of Scalar.value
      (** [Scalar_literal value] is the surface form of a bare scalar at the
          head of a pipeline: [42], ["hello"], [true]. The pipeline's source is
          the value itself. *)
  | Row_literal of (column_reference * Scalar.value) list
      (** [Row_literal fields] is the surface form of a bare row at the head of
          a pipeline: [(id = 1, name = "alice")] parses as a list of two fields
          whose column references are unqualified. A qualified spelling such as
          [(users.id = 1)] parses with [qualifier = Some "users"] on the
          reference. The empty row [()] parses as [Row_literal []]. Fields are
          in source order; the parser rejects duplicate qualified-name pairs. *)
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
          table whose declared type is the carried [type_expression]. Yields a
          one-row [(created : string)] relation. *)
  | Create_table_seeded of { table_name : string; source : t }
      (** [Create_table_seeded { table_name; source }] is the surface form
          [<value-pipeline> | create table <name>] -- creates [table_name] from
          [source]'s row type and seeds it with [source]'s rows. The target type
          is derived from [source]'s type at eval time. Yields a one-row
          [(created : string)] relation. *)
  | Relation_literal of {
      relation_type : type_expression;
      rows : (column_reference * Scalar.value) list list;
    }
      (** [Relation_literal { relation_type; rows }] is the surface form
          [relation (id: int64, name: string) { (id = 1, name = "alice"), ... }]
          — a relation whose type is declared up front and whose rows are
          self-describing row literals. The empty form [relation (...) {}]
          parses with [rows = []]. Field names inside each row come straight
          from the surface; each row is validated and reordered against
          [relation_type] during lowering. *)
  | Catalog_source
      (** [Catalog_source] is the surface form of the bare [catalog] keyword at
          pipeline-source position. It yields the database's catalog as a value
          whose entries are every table's name paired with its rows. The
          evaluator opens a per-table cursor lazily for each entry, scoped to
          the read transaction. *)
  | Tables of { input : t }
      (** [Tables { input }] is the surface form [input | tables]. Takes a
          catalog value on the left and yields a one-column [(name: string)]
          relation, one row per table in [input], in the catalog's cursor order.
          A user-facing error fires at eval time if [input] is not a catalog. *)
