(** Surface-driven seeder for the example tables that the [--demo-data] REPL
    flag and the documentation doctest harness consume.

    The script lives as an OCaml [string list] of surface-form REPL statements
    rather than a resource file. When a future slice introduces a "load DDL/DML
    from a file" story the script can move there; today's surface doesn't need
    it.

    The shape seeded today happens to match what [Fixture] populates in the test
    layer, but the two are deliberately decoupled: either is free to evolve
    without touching the other. *)

val script : string list
(** The example-table creation and row-insertion statements, one per element, in
    the order they must execute. Each element is a single REPL line: a
    [:create table] statement or a [\{...\} | insert into <table>] pipeline. *)

val run : Storage.environment -> unit
(** [run environment] seeds the example tables into [environment] by feeding
    {!script} through {!Repl.run} with a discarding formatter. Idempotent at the
    table level: if every table named in {!script} is already in the catalog,
    [run] returns without writes. Otherwise it runs the whole script and raises
    [Failure] if any statement produces an error line, so a script bug surfaces
    loudly instead of being absorbed by the REPL's per-line error guard. *)
