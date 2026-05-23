(** Data-definition AST: the statement universe.

    A DDL statement inspects or mutates the catalog itself rather than the rows
    of any table. The parser marks a DDL statement with the leading [:] sigil;
    the [Ast.program] wrapper bridges the DDL and pipeline universes at parse
    time, and the REPL dispatches on the wrapper to call the right
    {!Ddl_executor} entry point.

    This module owns the AST and result-type vocabulary alone — every surface
    language produces these constructors and the REPL pattern-matches on them.
    The catalog-touching executor that runs a statement lives in
    {!Ddl_executor}; the split keeps the AST free of any storage dependency, so
    a future surface (SQL, scripting) can build {!t} values without pulling the
    executor in.

    The constructors are [List_tables], [Drop_table], and [Create_table]. The
    table-type-introspection statement [:describe] was retired once the [type]
    pipe operator gave the surface language a uniform way to ask the same
    question. The canonical-form printer that pairs with the parser lives in
    {!Dovetail_ddl.Format} and satisfies the round-trip property
    [parse(format(s)) = s].

    DDL does not pass through [Lower] / [Translate] / [Physical] / [Eval] —
    those layers carry no knowledge of DDL. The REPL classifies a statement,
    opens the matching transaction kind, and hands the statement straight to
    {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write}. *)

module Scalar = Dovetail_core.Scalar

type field = { name : string; kind : Scalar.kind }
(** A single column declaration in a [Create_table] statement. Deliberately
    distinct from {!Row.field}: the DDL surface has no notion of qualified
    columns, so the qualifier is absent here. The parser resolves the kind name
    ([Int64], [String], [Bool]) to a {!Scalar.kind} at parse time, so every
    [field] value already carries a real kind. *)

type t =
  | List_tables
      (** [List_tables] is the surface form [:list tables]. Returns every table
          name bound in the catalog, in cursor (byte-sorted) order. Carries no
          body — the empty surface form is the whole statement. *)
  | Drop_table of { table_name : string }
      (** [Drop_table { table_name }] is the surface form [:drop table <name>].
          Removes the named table's catalog entry and its storage subDB in a
          single write transaction. The catalog-aware "no such table" check
          lives inside {!Ddl_executor.execute_write}, where it shares scope with
          the writes it guards. *)
  | Create_table of {
      table_name : string;
      fields : field list;
      primary_key : string list;
    }
      (** [Create_table { table_name; fields; primary_key }] is the surface form
          [:create table <name> (col: kind, ...) primary key (col, ...)].
          Declares a new table: creates its storage subDB and writes its
          [Relation.kind] into the catalog, all inside a single write
          transaction. The fields appear in declaration order; [primary_key]
          names columns drawn from [fields], in key order. The catalog-aware
          "table already exists" check lives inside
          {!Ddl_executor.execute_write}. *)

type read_result =
  | Listed of string list
      (** A read DDL statement's outcome. [Listed names] is the result of
          [List_tables]: every table name from the catalog, in cursor
          (byte-sorted) order. *)

type write_result =
  | Dropped of string
      (** A write DDL statement's outcome. [Dropped table_name] is the result of
          [Drop_table]: the name of the table that was removed. *)
  | Created of string
      (** [Created table_name] is the result of [Create_table]: the name of the
          table that was created. *)

val classify : t -> [ `Read | `Write ]
(** [classify statement] returns the transaction permission the REPL should open
    for [statement]: [`Read] for a statement that only inspects the catalog,
    [`Write] for one that mutates it. The REPL uses this to pick between
    {!Dovetail_storage.Engine.with_read_transaction} and
    {!Dovetail_storage.Engine.with_write_transaction}, and to dispatch to
    {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write} afterwards.
    The two dispatch decisions read off the same constructor, so they cannot
    drift. *)

val validate : t -> (unit, string) result
(** [validate statement] runs the structural checks that depend only on
    [statement] itself: no catalog access, no transaction. For a [Create_table],
    five rules are checked in order and the first failure short-circuits the
    rest:

    + the column list is non-empty;
    + no column name is repeated in the column list;
    + the primary-key list is non-empty;
    + every primary-key column names a field in the column list;
    + no primary-key column is repeated in the primary-key list.

    All other constructors return [Ok ()]. Errors are formatted as
    [DDL: create table "<name>": <detail>] and are intended to be raised at the
    REPL between parse and transaction so structural failures do not pay the
    cost of a writer-lock acquisition. *)
