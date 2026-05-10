(** Hardcoded fixture data populated lazily into a fresh database.

    Slice 1 ships the [users] table; slice 4 adds [orders]. The fixture is the
    only data producer until DDL/DML lands in a later slice. *)

val populate_if_empty : Storage.environment -> unit
(** [populate_if_empty environment] writes the [users] and [orders] schemas and
    their fixture rows in a single write transaction. Each table is written only
    if the catalog has no entry for it, so the call is idempotent: running it on
    an already-populated environment is a no-op, and adding a new fixture table
    to an environment that already has the earlier ones populates only the new
    table. *)
