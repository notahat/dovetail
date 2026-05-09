(** Hardcoded fixture data populated lazily into a fresh database.

    Slice 1 ships a single fixture: a [users] table with five rows. The fixture
    is the only data producer until DDL/DML lands in a later slice. *)

val populate_if_empty : Storage.environment -> unit
(** [populate_if_empty environment] writes the [users] schema and its five
    fixture rows in a single write transaction, but only if the catalog has no
    entry for [users]. Idempotent: running it on an already-populated
    environment is a no-op. *)
