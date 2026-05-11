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

val put :
  map -> [ `Read | `Write ] transaction -> key:string -> value:string -> unit
(** [put map transaction ~key ~value] writes [key]→[value], silently overwriting
    any existing value at [key]. *)

val get : map -> [> `Read ] transaction -> key:string -> string option
(** [get map transaction ~key] returns [Some v] if [key] is bound, else [None].
*)

val iter_seq : map -> [> `Read ] transaction -> (string * string) Seq.t
(** [iter_seq map transaction] returns every key-value pair in the map, in key
    order. Currently materialised eagerly into a list and wrapped as a [Seq.t]
    -- the [lmdb] package's streaming dispenser doesn't compose cleanly with our
    scope-bound read transactions, and slice 1's fixture is too small for it to
    matter. Revisit when a slice needs to scan enough rows that materialisation
    is the wrong choice. *)

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
