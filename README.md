# Dovetail

A small relational database in OCaml, built on top of LMDB. Two query
languages (a pipeline-style relational-algebra language, and SQL on top)
sit over a Volcano-style executor and a hand-rolled storage layer.

This is a learning vehicle, not production software.

## Building and running

You'll need OCaml 5.2 with Dune.

```sh
opam exec -- dune build              # compile
opam exec -- dune test               # run all alcotest suites
opam exec -- dune build @fmt --auto-promote   # format
./dovetail                           # run the REPL (default env: ./dovetail-data)
./dovetail /tmp/dovetail-play        # ...or pass a custom data directory
./dovetail --demo-data /tmp/play     # ...or seed the example tables on first launch
./dovetail --sql                     # ...or speak SQL instead of the pipeline language
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

## Trying it out with Docker

If you'd rather not set up an OCaml toolchain, the included
[`Dockerfile`](Dockerfile) builds the binary and starts the REPL with
the demo tables already seeded:

```sh
docker build -t dovetail .
docker run -it --rm dovetail          # relational-algebra REPL
docker run -it --rm dovetail --sql    # SQL REPL
```

The `-it` flags are required — the REPL is interactive. The image's
entrypoint runs `dovetail --demo-data /data`, so anything after the
image name is appended (that's how `--sql` reaches the binary), and
re-seeding an already-seeded directory is a no-op. The LMDB data
directory lives in the container's `/data` volume and is discarded
with `--rm`; mount a named volume to keep it between runs:

```sh
docker run -it -v dovetail-data:/data dovetail
```

## Query languages

Two surfaces sit over the same logical and physical plans, so they
share catalog lookup, type checking, evaluation, and error messages.
The REPL speaks one surface per session, chosen at launch; `--demo-data`
seeds two example tables, `users` and `orders`, for either to read
against.

### Relational algebra (default)

The default surface is pipeline-shaped: name a relation, then chain
operators (`restrict`, `project`, `join`, and friends) with `|`; the
[relational-algebra reference](docs/reference/ra/README.md) lists the
full set of sources, operators, and sinks. The canonical
multi-operator query joins two tables and projects:

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

### SQL (`--sql`)

Launch with `--sql` for a small SQL surface, with a psql-style `sql>`
prompt and bordered result tables. It understands a single-table
`SELECT` -- a select list, a `FROM`, and an optional `WHERE` -- which
lowers to the same scan/restrict/project plan the relational-algebra
surface builds:

```
sql> SELECT name, email FROM users WHERE active
 name  |       email       
-------+-------------------
 Alice | alice@example.com 
 Carol | carol@example.com 
 Dave  | dave@example.com  
(3 rows)
```

See [the query-language guide](docs/tutorial/README.md) for the
relational-algebra walkthrough -- tutorial, per-operator reference, and
the expression and projection sublanguages -- and the
[SQL reference](docs/reference/sql/README.md) for the `SELECT` grammar.

## Roadmap

### Next up

A documentation overhaul
([plan 29](docs/plans/29-documentation-overhaul.md)): status banners
separating as-built docs from proposals, promotion of design
rationale out of frozen plan files into `docs/internals/`, doctest
coverage for the SQL reference, a query-lifecycle walkthrough, new
tutorial chapters, and an odoc build.

### Beyond

Unordered backlog. Some items are foundational, some are operator
additions, some are tooling and infrastructure; the order they land in
is not committed to here.

- Primary key range lookups.
- Autoincrement columns.
- UUID columns, with automatic UUIDv7 generation.
- Secondary indexes on columns other than the primary key.
- Hash join, for joins where neither side has a useful index.
- NULL values and option-typed columns. Cross-cutting: touches `Value`,
  `Row`, `Relation`, `Encoding`, `Expression`, and `Eval`.
- Set operators: `distinct`, `union`, `intersect`, `difference`.
- `sort` and `limit`.
- Outer joins.
- Aggregation (`count`, `sum`, etc.), group by, having.
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
- A cost-based query optimiser: statistics collection, a cost model,
  plan search.
- SQL elaboration beyond the initial frontend — joins, aggregation,
  subqueries, the rest of SELECT.
- A network protocol so the database can run as a separate process.
- Network client libraries.
- An embeddable API for use as a library.
