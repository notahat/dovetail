(** Data-definition statements.

    DDL is the second universe at the top of the surface language: a statement
    that inspects or mutates the catalog itself rather than the rows of any
    table. The parser marks a DDL statement with the leading [:] sigil; the
    [Ast.program] wrapper bridges the two universes at parse time, and the REPL
    dispatches on the wrapper to call the right execute entry point here.

    Slice 12 lands [List_tables] and [Drop_table] only. The remaining statements
    ([Describe], [Create_table]) arrive in slice 13, paired so the round-trip
    property [parse(format(s)) = s] lands in one PR.

    DDL does not pass through [Lower] / [Translate] / [Physical] / [Eval] —
    those layers carry no knowledge of DDL. The REPL classifies a statement,
    opens the matching transaction kind, and hands the statement straight to
    {!execute_read} or {!execute_write}. *)

type statement =
  | List_tables
      (** [List_tables] is the surface form [:list tables]. Returns every table
          name bound in the catalog, in cursor (byte-sorted) order. Carries no
          body — the empty surface form is the whole statement. *)
  | Drop_table of { table_name : string }
      (** [Drop_table { table_name }] is the surface form [:drop table <name>].
          Removes the named table's catalog entry and its storage subDB in a
          single write transaction. The catalog-aware "no such table" check
          lives inside {!execute_write}, where it shares scope with the writes
          it guards. *)

type read_result =
  | Listed of string list
      (** A read DDL statement's outcome. [Listed names] is the result of
          [List_tables]: every table name from the catalog, in cursor
          (byte-sorted) order. Slice 13 will add [Described of Schema.t] when
          [:describe] lands. *)

type write_result =
  | Dropped of string
      (** A write DDL statement's outcome. [Dropped table_name] is the result of
          [Drop_table]: the name of the table that was removed. Slice 13 will
          add [Created of string] when [:create table] lands. *)

val classify : statement -> [ `Read | `Write ]
(** [classify statement] returns the transaction permission the REPL should open
    for [statement]: [`Read] for a statement that only inspects the catalog,
    [`Write] for one that mutates it. The REPL uses this to pick between
    {!Storage.with_read_transaction} and {!Storage.with_write_transaction}, and
    to dispatch to {!execute_read} or {!execute_write} afterwards. The two
    dispatch decisions read off the same constructor, so they cannot drift. *)

val execute_read :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  statement ->
  read_result
(** [execute_read environment transaction statement] runs a read-only DDL
    statement and returns its result. Accepts the polymorphic [[> `Read]]
    transaction so [:list tables] doesn't unnecessarily serialise against LMDB's
    writer lock.

    Slice 12 implements only [List_tables]. Passing a write-only DDL constructor
    (e.g. [Drop_table]) is a contract violation: the REPL is required to call
    {!classify} first and route write statements to {!execute_write}, so
    reaching this with a write statement would be a layering bug. *)

val execute_write :
  Storage.environment ->
  [ `Read | `Write ] Storage.transaction ->
  statement ->
  write_result
(** [execute_write environment transaction statement] runs a write DDL statement
    and returns its result. Requires a read-write transaction at the type level.

    Slice 12 step 2 leaves the body as [assert false]; step 5a fills in the
    [Drop_table] arm. Passing a read-only DDL constructor (e.g. [List_tables])
    is a contract violation per the same routing rule as {!execute_read}.

    Raises [Failure] on catalog-aware errors raised inside the write transaction
    (e.g. dropping a table that does not exist). The raise aborts the in-flight
    write via the standard exception path of {!Storage.with_write_transaction}.
*)
