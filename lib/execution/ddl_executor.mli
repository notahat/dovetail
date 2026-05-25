(** Executor for data-definition statements.

    [Ddl_executor] is the catalog-touching twin of {!Eval}: it takes a
    {!Ddl.Statement.t} and runs it against the {!Storage.Engine} environment,
    returning the matching {!Ddl.Statement.read_result}. The AST it consumes
    lives in {!Ddl.Statement} — the split keeps the AST vocabulary free of any
    storage dependency.

    Today's only statement [:list tables] runs inside a read transaction; the
    REPL opens the transaction and calls {!execute_read}. The write-side entry
    point that paired with retired DDL forms has been removed. *)

module Ddl = Dovetail_ddl
module Storage = Dovetail_storage

val execute_read :
  Storage.Engine.environment ->
  [> `Read ] Storage.Engine.transaction ->
  Ddl.Statement.t ->
  Ddl.Statement.read_result
(** [execute_read environment transaction statement] runs a read-only DDL
    statement and returns its result. Accepts the polymorphic [[> `Read]]
    transaction so [:list tables] doesn't unnecessarily serialise against LMDB's
    writer lock. *)
