(** LMDB environment, transactions, and named byte-keyed maps.

    Storage is the thin layer above the [lmdb] package that fixes a single
    shape for the rest of dovetail to talk against: every key and every
    value is a [string] of bytes. Encoding and decoding live above this
    layer. Schemas, tuples, and the catalog do not appear here.

    Transactions are scope-bound via {!with_read_txn} and {!with_write_txn}.
    A txn is alive only inside its callback; cursors and dispensers backed
    by the txn become invalid as soon as the callback returns. *)

(** A handle to an LMDB environment. *)
type env

(** A transaction handle, parameterised by its permissions. *)
type -'perm txn constraint 'perm = [< `Read | `Write ]

(** A handle to a named byte-keyed sub-database within an env. *)
type map

(** [open_env path] opens (creating [path] as a directory if necessary)
    an LMDB environment. The returned env must be closed with
    {!close_env} on shutdown.

    @param map_size virtual address space size in bytes; default 1 GiB.
    @param max_maps maximum number of named subDBs the env can hold;
      default 4096. *)
val open_env : ?map_size:int -> ?max_maps:int -> string -> env

(** [close_env env] closes the environment. *)
val close_env : env -> unit

(** [with_read_txn env f] runs [f] in a read-only transaction. The txn
    aborts (and any cursors created against it become invalid) when [f]
    returns or raises. Re-raises if [f] raises. *)
val with_read_txn : env -> ([ `Read ] txn -> 'a) -> 'a

(** [with_write_txn env f] runs [f] in a read-write transaction. The
    transaction commits when [f] returns normally; if [f] raises, the
    transaction aborts and the exception is re-raised. *)
val with_write_txn : env -> ([ `Read | `Write ] txn -> 'a) -> 'a

(** [open_map env txn ~name] returns the named subDB, or [None] if no
    such subDB exists in the env. Safe to call inside a read txn. *)
val open_map : env -> [> `Read ] txn -> name:string -> map option

(** [create_map env txn ~name] opens the named subDB, creating it if it
    does not exist. Must be called inside a read-write txn. *)
val create_map : env -> [ `Read | `Write ] txn -> name:string -> map

(** [put map txn ~key ~value] writes [key]→[value], silently overwriting
    any existing value at [key]. *)
val put : map -> [ `Read | `Write ] txn -> key:string -> value:string -> unit

(** [get map txn ~key] returns [Some v] if [key] is bound, else [None]. *)
val get : map -> [> `Read ] txn -> key:string -> string option

(** [iter_seq map txn] returns every key-value pair in the map, in key
    order. Currently materialised eagerly into a list and wrapped as a
    [Seq.t] -- the [lmdb] package's streaming dispenser doesn't compose
    cleanly with our scope-bound read txns, and slice 1's fixture is
    too small for it to matter. Revisit when a slice needs to scan
    enough rows that materialisation is the wrong choice. *)
val iter_seq : map -> [> `Read ] txn -> (string * string) Seq.t
