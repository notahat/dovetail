# Dovetail

A small relational database in OCaml, built on top of LMDB. Two query
languages (a pipeline-style relational-algebra language, and SQL on top)
sit over a Volcano-style executor and a hand-rolled storage layer.

This is a learning vehicle, not production software. The plan deliberately
delivers the system as thin vertical slices — each slice adds one
operator's worth of code at every layer, end to end. See
[`docs/plans/00-initial-plan.md`](docs/plans/00-initial-plan.md) for the
foundational design and the slice plans (`02-...`, `03-...`) for the work
in flight.

## Building and running

OCaml 5.2 in a local opam switch at the repo root.

```sh
opam exec -- dune build              # compile
opam exec -- dune test               # run all alcotest suites
opam exec -- dune build @fmt --auto-promote   # format
./dovetail                           # run the REPL (default env: ./dovetail-data)
./dovetail /tmp/dovetail-play        # ...or pass a custom data directory
```

`./dovetail` is a small wrapper around `opam exec -- dune exec dovetail`
so the REPL can be launched with a single command.

See [`CLAUDE.md`](CLAUDE.md) for project-specific naming and tooling
conventions.

## Query language examples

The REPL queries a fixture with two tables, `users` (id, name, email,
active) and `orders` (id, user_id, description, amount). A bare table
name reads the whole table; pipeline operators `restrict`, `project`,
`cross`, and `join` compose with `|`:

```
> users | restrict active | project name, email
| users.name | users.email       |
|------------|-------------------|
| Alice      | alice@example.com |
| Carol      | carol@example.com |
| Dave       | dave@example.com  |
```

Joins use qualified column references, and the rest of the pipeline can
keep going past the join:

```
> users | join orders on users.id = orders.user_id | project name, description, amount
| users.name | orders.description | orders.amount |
|------------|--------------------|---------------|
| Alice      | Coffee             |             5 |
| Alice      | Bagel              |             4 |
| Bob        | Tea                |             3 |
| Carol      | Sandwich           |             8 |
| Carol      | Cake               |             6 |
| Eve        | Cookie             |             2 |
```

Predicates support the six comparison operators (`=`, `<>`, `<`, `<=`,
`>`, `>=`), boolean `and` / `or` / `not`, and parentheses; literals can
be integers, strings, or booleans:

```
> orders | restrict amount >= 5 and not (description = "Cake")
| orders.id | orders.user_id | orders.description | orders.amount |
|-----------|----------------|--------------------|---------------|
|         1 |              1 | Coffee             |             5 |
|         4 |              3 | Sandwich           |             8 |
```

## Layer diagram

The query pipeline runs top-to-bottom from text to tuples and back to text.
The storage stack sits below it, used by `Eval` and the catalog.

```
  Query pipeline                                  Storage stack
  ──────────────                                  ─────────────

  "users | join orders on users.id = orders.user_id"
         │
         │  Parser   (angstrom)
         ▼
       Ast.t        — surface AST; mirrors syntax
         │
         │  Lower
         ▼
     Logical.t      — relational algebra; what the query computes
         │
         │  Translate
         ▼
     Physical.t     — physical operators; how to compute it
         │
         │  Eval ────────────────────────────►  Catalog       — name → Schema.t
         ▼                                          │
     Relation.t     — schema + Seq.t of tuples      │  uses
         │                                          ▼
         │  Relation.print                      Encoding      — keys (byte-
         ▼                                          │          comparable),
       output                                       │          tuple values
                                                    │          (Marshal)
                                                    │  uses
                                                    ▼
                                                Storage       — LMDB env, txns,
                                                    │          byte-keyed maps
                                                    ▼
                                                  LMDB
```

`Fixture` sits beside `Catalog` and the storage stack, populating
hardcoded `users` and `orders` tables on first run. Once DDL/DML
lands in a later slice it goes away.

## Layers

### Query pipeline

| Layer       | Type                                     | Role                                                                                                                       |
| ----------- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `Parser`    | `string -> (Ast.t, error) result`              | Surface syntax → AST, built on `angstrom`. Bare identifiers and `\|`-separated `restrict`, `project`, `cross`, and `join ... on` pipeline steps so far. |
| `Ast`       | `t = Relation_name \| Restrict \| Project \| CrossProduct \| Join \| ...` | What the user typed, structured. No semantics yet.                                                                                |
| `Lower`     | `Ast.t -> Logical.t`                           | Replace each syntactic node with the algebraic operator it denotes. `Ast.Join` desugars to `Logical.Restrict (Logical.CrossProduct ..., predicate)`. |
| `Logical`   | `t = Scan \| Restrict \| Project \| CrossProduct \| ...` | Algebra: *what* the query computes, with no execution detail. `Restrict` is σ; `Project` is π; `CrossProduct` is ×.                  |
| `Translate` | `Logical.t -> Physical.t`                      | Pick a physical strategy per operator. Folds `Restrict` over `CrossProduct` into a single `NestedLoopJoin`; future home of further optimisation. |
| `Physical`  | `t = FullScan \| Filter \| Project \| CrossProduct \| NestedLoopJoin \| ...` | Concrete execution plan: cursors, filters, projections, nested-loop cross product and join, future hash joins, etc.                  |
| `Predicate` | `t = Compare {...}`                            | Predicate sublanguage shared by `Logical.Restrict` and `Physical.Filter`. Each side is a column ref (bare or `qualifier.name`) or a literal. `Predicate.resolve` validates and caches lookup. |
| `Projection`| `t = Schema.column_reference list`             | Projection sublanguage shared by `Logical.Project` and `Physical.Project`. `Projection.resolve` validates and returns a row-rewriter.|
| `Eval`      | `env -> txn -> Physical.t -> Relation.t` | Volcano executor. Each operator returns a `Relation.t` whose `tuples` seq is pulled lazily.                                |
| `Relation`  | `'tag t = { schema; tuples }`            | Schema-tagged stream of tuples. Phantom `'tag` distinguishes set vs bag semantics.                                         |

### Storage stack

| Layer      | Role                                                                                        |
| ---------- | ------------------------------------------------------------------------------------------- |
| `Storage`  | Thin wrapper over LMDB. Env, scope-bound read/write transactions, byte-keyed sub-databases. |
| `Encoding` | Byte-comparable key encoding (sign-flipped BE for `int64`); `Marshal` for tuple values.     |
| `Catalog`  | Persistent table-name → `Schema.t` map, backed by a single `catalog` subDB.                 |

### Data types

| Module   | What it carries                                                                                    |
| -------- | -------------------------------------------------------------------------------------------------- |
| `Value`  | `Int64 \| String \| Bool` runtime values, plus a parallel `Kind.t` for static schema declarations. |
| `Schema` | Ordered field list + primary-key column names. `Schema.tuple = Value.t array`.                     |
| `Relation` | (See above.) Phantom-typed for set/bag semantics.                                                |

## Roadmap

### Next up

Ordered. Each item lands as its own slice plan (`docs/plans/NN-...`) with
sub-steps; the ordering here is firm, but the scope of slices 11–13 will
be pinned down when those slices start.

1. **Slice 8 — Primary-key range scans.** In flight. First time
   `Translate` chooses between `FullScan` and `IndexScan`.
2. **Slice 9 — Indexed nested-loop join over the primary key.** Makes
   joins efficient when one side's join column is the primary key — one
   full scan of the outer, one PK probe per row. No secondary indexes
   yet; those wait for a workload that motivates them.
3. **Slice 10 — Query-language documentation.** Short tutorial intro
   followed by reference sections for each operator and for the
   expression and projection sublanguages. Covers only what exists.
4. **Slice 11 — DML as an RA-language extension.** Statement-level
   forms for inserting rows, alongside the existing pipeline syntax.
   Update and delete may land here or follow on. Exercised against the
   existing fixture.
5. **Slice 12 — DDL as an RA-language extension.** Statement-level
   `create table` and `drop table`. Replaces the fixture-creation path.
6. **Slice 13 — Minimal SQL frontend.** A second front-end — SQL
   parser, SQL AST, SQL→logical lowering — feeding the existing logical
   and physical IRs. Deliberately limited (no NULLs, scope otherwise
   TBD): the focus is on how the architecture splits between two
   surface languages, not on covering SQL.

### Beyond

Unordered backlog. Some items are foundational, some are operator
additions, some are tooling and infrastructure; the order they land in
is not committed to here.

- Secondary indexes on columns other than the primary key.
- Hash join, for joins where neither side has a useful index.
- NULL values and option-typed columns. Cross-cutting: touches `Value`,
  `Schema`, `Encoding`, `Expression`, and `Eval`.
- Set operators: `distinct`, `union`, `intersect`, `difference`.
- `sort` and `limit`.
- Outer joins.
- Aggregation, group by, having.
- Update and delete, if not bundled into the DML slice.
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
