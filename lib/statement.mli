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

    Slice 12 lands [List_tables] and [Drop_table] only. The remaining statements
    ([Describe], [Create_table]) arrive in slice 14, paired so the round-trip
    property [parse(format(s)) = s] lands in one PR.

    DDL does not pass through [Lower] / [Translate] / [Physical] / [Eval] —
    those layers carry no knowledge of DDL. The REPL classifies a statement,
    opens the matching transaction kind, and hands the statement straight to
    {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write}. *)

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

type read_result =
  | Listed of string list
      (** A read DDL statement's outcome. [Listed names] is the result of
          [List_tables]: every table name from the catalog, in cursor
          (byte-sorted) order. Slice 14 will add [Described of Schema.t] when
          [:describe] lands. *)

type write_result =
  | Dropped of string
      (** A write DDL statement's outcome. [Dropped table_name] is the result of
          [Drop_table]: the name of the table that was removed. Slice 14 will
          add [Created of string] when [:create table] lands. *)

val classify : t -> [ `Read | `Write ]
(** [classify statement] returns the transaction permission the REPL should open
    for [statement]: [`Read] for a statement that only inspects the catalog,
    [`Write] for one that mutates it. The REPL uses this to pick between
    {!Storage.with_read_transaction} and {!Storage.with_write_transaction}, and
    to dispatch to {!Ddl_executor.execute_read} or {!Ddl_executor.execute_write}
    afterwards. The two dispatch decisions read off the same constructor, so
    they cannot drift. *)
