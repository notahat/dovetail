(** The catalog: a persistent map from table name to [Schema.t].

    Backed by a single LMDB subDB called [catalog], keyed by the table name as
    UTF-8 bytes with [Marshal]-encoded schemas as values. The subDB is created
    lazily on the first {!put}; reads against an environment that has never been
    written return [None] rather than raising.

    The Marshal coupling to OCaml's runtime representation is accepted for now
    and will be revisited alongside composite-key encoding. *)

module Schema = Dovetail_core.Schema

val get :
  Engine.environment ->
  [> `Read ] Engine.transaction ->
  table_name:string ->
  Schema.t option
(** [get environment transaction ~table_name] returns the schema bound to
    [table_name], or [None] if no such binding exists (including the case where
    the catalog subDB has not yet been created). Safe to call inside a read-only
    transaction. *)

val put :
  Engine.environment ->
  [ `Read | `Write ] Engine.transaction ->
  table_name:string ->
  Schema.t ->
  unit
(** [put environment transaction ~table_name schema] writes [schema] under
    [table_name], creating the catalog subDB if it does not yet exist.
    Overwrites any existing binding silently. Must be called inside a read-write
    transaction. *)

val list_table_names :
  Engine.environment -> [> `Read ] Engine.transaction -> string list
(** [list_table_names environment transaction] returns the names of every table
    bound in the catalog, in byte-sorted (cursor) order. Returns [] if the
    catalog subDB has not yet been created. Safe to call inside a read-only
    transaction. *)

val delete :
  Engine.environment ->
  [ `Read | `Write ] Engine.transaction ->
  table_name:string ->
  unit
(** [delete environment transaction ~table_name] removes the catalog binding for
    [table_name], if any. A no-op when no such binding exists, and a no-op when
    the catalog subDB has not yet been created -- the catalog-aware "no such
    table" error message lives in the higher layer
    ({!Ddl_executor.execute_write}) so it can share scope with the storage drop.
    Must be called inside a read-write transaction. *)

val table_subdb_name : string -> string
(** [table_subdb_name table_name] returns the name of the storage subDB that
    holds the rows of [table_name]: the [table:] namespace convention
    ([table:users] for [users], and so on). Single source of truth for the
    convention -- {!Eval} and {!Ddl_executor.execute_write} both ask here rather
    than constructing the string locally. *)
