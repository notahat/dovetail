# Dovetail

A small relational database in OCaml, built on top of LMDB. Two query
languages (a pipeline-style relational-algebra language, and SQL on top)
sit over a Volcano-style executor and a hand-rolled storage layer.

This is a learning vehicle, not production software.

## Building and running

OCaml 5.2 in a local opam switch at the repo root.

```sh
opam exec -- dune build              # compile
opam exec -- dune test               # run all alcotest suites
opam exec -- dune build @fmt --auto-promote   # format
./dovetail                           # run the REPL (default env: ./dovetail-data)
./dovetail /tmp/dovetail-play        # ...or pass a custom data directory
./dovetail --demo-data /tmp/play     # ...or seed the example tables on first launch
./dovetail --show-logical            # ...or print each query's logical plan
./dovetail --show-physical           # ...or print each query's physical plan
```

`--show-logical` and `--show-physical` are dev-facing EXPLAIN-style
debug flags: each prints the relevant plan to stdout before the
query's result rows. Combine them and both plans render in pipeline
order — logical first, then physical.

`./dovetail` is a small wrapper that execs the prebuilt
`_build/default/bin/main.exe`, forwarding any arguments. It does not
build — run `dune build` first (or keep the `dune runtest -w` watcher
up, which keeps the artifact fresh).

See [`CLAUDE.md`](CLAUDE.md) for project-specific naming and tooling
conventions.

## Query language

Launched with `--demo-data`, the REPL seeds two example tables,
`users` and `orders`, for queries to read against. Pipeline
operators (`restrict`, `project`, `cross`, `join`) compose with
`|`, and the canonical multi-operator query joins them and
projects:

```
> users | join orders on users.id = orders.user_id | project name, description, amount
relation (users.name: string, orders.description: string, orders.amount: int64) {
  (users.name = "Alice", orders.description = "Coffee", orders.amount = 5),
  (users.name = "Alice", orders.description = "Bagel", orders.amount = 4),
  (users.name = "Bob", orders.description = "Tea", orders.amount = 3),
  (users.name = "Carol", orders.description = "Sandwich", orders.amount = 8),
  (users.name = "Carol", orders.description = "Cake", orders.amount = 6),
  (users.name = "Eve", orders.description = "Cookie", orders.amount = 2)
}
```

See [`docs/query-language.md`](docs/query-language.md) for the full
guide -- tutorial, per-operator reference, and the expression and
projection sublanguages.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for the layer
diagram, per-layer reference for the query pipeline and storage stack,
and the sub-library dependency graph under `lib/`.

## Roadmap

### Next up

Ordered. Each item lands as its own slice plan (`docs/plans/NN-...`)
with sub-steps; the ordering here is firm, but the scope of slice 17
will be pinned down when that slice starts.

1. **Slice 17 — Minimal SQL frontend.** A second front-end — SQL
   parser, SQL AST, SQL→logical lowering — feeding the existing logical
   and physical IRs. Deliberately limited (no NULLs, scope otherwise
   TBD): the focus is on how the architecture splits between two
   surface languages, not on covering SQL.

### Beyond

Unordered backlog. Some items are foundational, some are operator
additions, some are tooling and infrastructure; the order they land in
is not committed to here.

- Primary key range lookups.
- Secondary indexes on columns other than the primary key.
- Hash join, for joins where neither side has a useful index.
- NULL values and option-typed columns. Cross-cutting: touches `Value`,
  `Row`, `Relation`, `Encoding`, `Expression`, and `Eval`.
- Set operators: `distinct`, `union`, `intersect`, `difference`.
- `sort` and `limit`.
- Outer joins.
- Aggregation, group by, having.
- Update and delete (the slice-11 DML deferrals), with the
  upstream-identity validator the DML design doc describes and an
  assignments expression sublanguage.
- Arithmetic and value-producing expressions, so predicates like
  `age + 1 > 18` and computed projection columns work.
- Function calls in expressions.
- Subqueries.
- A `rename` operator on the surface RA language.
- Constraints beyond the primary key: NOT NULL, UNIQUE, CHECK, foreign
  keys.
- Additional data types: date/time, decimal, floating point, blob.
- Exposed transaction commands (begin / commit / rollback).
- EXPLAIN-style plan introspection.
- Schema introspection (list tables, describe table).
- A cost-based query optimiser: statistics collection, a cost model,
  plan search.
- SQL elaboration beyond the first slice — joins, aggregation,
  subqueries, the rest of SELECT.
- An internals walkthrough that follows a query through the layers.
- A network protocol so the database can run as a separate process.
- Network client libraries.
- An embeddable API for use as a library.
