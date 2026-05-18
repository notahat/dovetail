(** Executor for data-definition statements.

    [Ddl] is the catalog-touching twin of {!Eval}: it takes a {!Statement.t} and
    runs it against the {!Storage} environment, returning the matching
    {!Statement.read_result} or {!Statement.write_result}. The AST it consumes
    lives in {!Statement} — the split keeps the AST vocabulary free of any
    storage dependency.

    The REPL is responsible for routing: it asks {!Statement.classify} for the
    transaction permission, opens the corresponding transaction kind, and calls
    into {!execute_read} or {!execute_write} accordingly. *)

val execute_read :
  Storage.environment ->
  [> `Read ] Storage.transaction ->
  Statement.t ->
  Statement.read_result
(** [execute_read environment transaction statement] runs a read-only DDL
    statement and returns its result. Accepts the polymorphic [[> `Read]]
    transaction so [:list tables] doesn't unnecessarily serialise against LMDB's
    writer lock.

    Slice 12 implements only [List_tables]. Passing a write-only DDL constructor
    (e.g. [Drop_table]) is a contract violation: the REPL is required to call
    {!Statement.classify} first and route write statements to {!execute_write},
    so reaching this with a write statement would be a layering bug. *)

val execute_write :
  Storage.environment ->
  [ `Read | `Write ] Storage.transaction ->
  Statement.t ->
  Statement.write_result
(** [execute_write environment transaction statement] runs a write DDL statement
    and returns its result. Requires a read-write transaction at the type level.

    Passing a read-only DDL constructor (e.g. [List_tables]) is a contract
    violation per the same routing rule as {!execute_read}.

    Raises [Failure] on catalog-aware errors raised inside the write transaction
    (e.g. dropping a table that does not exist). The raise aborts the in-flight
    write via the standard exception path of {!Storage.with_write_transaction}.
*)
