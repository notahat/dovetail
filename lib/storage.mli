(** LMDB environment, transactions, and named byte-keyed maps.

    Storage is the thin layer above the [lmdb] package that fixes a single shape
    for the rest of dovetail to talk against: every key and every value is a
    [string] of bytes. Encoding and decoding live above this layer. Schemas,
    tuples, and the catalog do not appear here.

    Transactions are scope-bound via {!with_read_transaction} and
    {!with_write_transaction}. A transaction is alive only inside its callback;
    cursors and dispensers backed by the transaction become invalid as soon as
    the callback returns. *)

type environment
(** A handle to an LMDB environment. *)

type -'perm transaction constraint 'perm = [< `Read | `Write ]
(** A transaction handle, parameterised by its permissions. *)

type map
(** A handle to a named byte-keyed sub-database within an environment. *)

val open_environment : ?map_size:int -> ?max_maps:int -> string -> environment
(** [open_environment path] opens (creating [path] as a directory if necessary)
    an LMDB environment. The returned environment must be closed with
    {!close_environment} on shutdown.

    @param map_size virtual address space size in bytes; default 1 GiB.
    @param max_maps
      maximum number of named subDBs the environment can hold; default 4096. *)

val close_environment : environment -> unit
(** [close_environment environment] closes the environment. *)

val with_read_transaction : environment -> ([ `Read ] transaction -> 'a) -> 'a
(** [with_read_transaction environment f] runs [f] in a read-only transaction.
    The transaction aborts (and any cursors created against it become invalid)
    when [f] returns or raises. Re-raises if [f] raises. *)

val with_write_transaction :
  environment -> ([ `Read | `Write ] transaction -> 'a) -> 'a
(** [with_write_transaction environment f] runs [f] in a read-write transaction.
    The transaction commits when [f] returns normally; if [f] raises, the
    transaction aborts and the exception is re-raised. *)

val open_map :
  environment -> [> `Read ] transaction -> name:string -> map option
(** [open_map environment transaction ~name] returns the named subDB, or [None]
    if no such subDB exists in the environment. Safe to call inside a read
    transaction. *)

val create_map :
  environment -> [ `Read | `Write ] transaction -> name:string -> map
(** [create_map environment transaction ~name] opens the named subDB, creating
    it if it does not exist. Must be called inside a read-write transaction. *)

val drop_map :
  environment -> [ `Read | `Write ] transaction -> name:string -> unit
(** [drop_map environment transaction ~name] destroys the named subDB, including
    every key it holds. Raises [Invalid_argument] if no subDB by that name
    exists: this is a precondition the caller is expected to have enforced (e.g.
    {!Ddl.execute_write}'s catalog-aware "no such table" check before reaching
    the storage primitive). Must be called inside a read-write transaction. *)

val put :
  map -> [ `Read | `Write ] transaction -> key:string -> value:string -> unit
(** [put map transaction ~key ~value] writes [key]→[value], silently overwriting
    any existing value at [key]. *)

val get : map -> [> `Read ] transaction -> key:string -> string option
(** [get map transaction ~key] returns [Some v] if [key] is bound, else [None].
*)

val delete : map -> [ `Read | `Write ] transaction -> key:string -> unit
(** [delete map transaction ~key] removes [key] from [map]. A no-op if [key] is
    not bound, mirroring [get]'s tolerance of an absent key: callers that
    require an existence check are expected to perform it themselves (the
    catalog-aware "no such table" check inside {!Ddl.execute_write} is the
    motivating example). Must be called inside a read-write transaction. *)

val with_iter_seq :
  map -> [> `Read ] transaction -> ((string * string) Seq.t -> 'a) -> 'a
(** [with_iter_seq map transaction continue] opens a cursor over [map] and
    invokes [continue] with a one-shot sequence that pulls key-value pairs in
    key order directly from the live cursor.

    The sequence is only valid inside [continue]; using it after [continue]
    returns is undefined behaviour. The sequence is one-shot: once exhausted,
    re-iterating yields nothing. Partial consumption (returning from [continue]
    without draining the sequence) is safe -- the cursor and any remaining state
    are torn down when [continue] returns. *)
