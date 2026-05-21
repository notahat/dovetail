(** Hardcoded fixture data populated lazily into a fresh database, for unit
    tests that need a known set of rows to query against.

    The only callers are the unit-test suites that need data without paying the
    DDL/DML correctness dependency. The {!Demo_data} module in [lib/] serves the
    same shape through the surface for the [--demo-data] REPL flag and the
    doctest harness; the two are deliberately decoupled and free to drift. *)

module Row = Dovetail_core.Row
module Storage = Dovetail_storage

val users_rows : Row.data list
(** The five [users] rows, in primary-key order. Exposed so tests that compare
    pipeline output against the fixture have a single source of truth. *)

val orders_rows : Row.data list
(** The six [orders] rows, in primary-key order. Dave (user id 4) deliberately
    has no orders; Alice (id 1) and Carol (id 3) each have two. *)

val populate_if_empty : Storage.Engine.environment -> unit
(** [populate_if_empty environment] writes the [users] and [orders] kinds and
    their fixture rows in a single write transaction. Each table is written only
    if the catalog has no entry for it, so the call is idempotent: running it on
    an already-populated environment is a no-op, and adding a new fixture table
    to an environment that already has the earlier ones populates only the new
    table. *)
