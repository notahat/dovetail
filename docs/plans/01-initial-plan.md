# 01 — Initial plan

Dovetail is a relational database, built primarily as a learning project,
with the goal of evolving it into a useful tool. It implements relational
algebra as its core engine. It is queryable via two languages: a
pipeline-style relational-algebra (RA) language, and SQL. The SQL
implementation is built on top of the RA engine.

This document captures the foundational decisions for the project and the
broad-strokes slice plan. Tactical decisions (error handling style,
optimizer details, transaction model, full SQL surface, project module
layout, testing tooling) are deferred until a slice forces them.

## Goals

- Learn relational algebra, query planning, parsing, and storage encoding by
  building.
- Two surface languages — RA and SQL — both compiling to the same algebraic
  IR. The SQL implementation rides on top of the RA engine.
- Persist data to disk from day one.
- Keep the architecture pedagogically clear: each layer has a name and a
  responsibility a reader can identify.
- Leave a credible path toward the project becoming a useful tool: a real
  optimizer, transactions exposed as a feature, more types, more SQL.

## Non-goals (for v1)

- Concurrency beyond what LMDB gives for free (single-writer, multi-reader).
- Exposed transactions as a user feature.
- A network protocol or client/server split.
- A full SQL type system (decimal, date/time, blob, etc.).
- Full SQL surface area.
- A cost-based optimizer.
- Distributed operation.

## Architectural decisions

### Language and storage

- **OCaml**, with `dune` and `opam`. Chosen for excellent ADTs and pattern
  matching (which makes ASTs and IRs natural), strong module system (which
  makes "swap the storage backend later" feasible), and a pleasant parsing
  ecosystem.
- **LMDB** as the storage backend, via the `lmdb` opam bindings. Trades
  away the chance to learn page/buffer-pool/WAL internals in exchange for
  an idiomatic frontend language and a free MVCC-ACID storage layer. The
  storage abstraction is designed so a custom pager could replace LMDB
  later.

### Engine semantics

- **Bag-based engine and IR.** Every relation is conceptually a multiset.
  This matches SQL's reality and matches every production engine.
- **Set-vs-bag tracked at the OCaml type level on the surface RA.**
  `Set<S>` is a `Bag<S>` with a static no-duplicates guarantee. Operators
  that preserve set-ness preserve the type; operators that don't (`π`,
  bag union) downgrade to `Bag` unless followed by `distinct`, which
  upcasts.
- **Named attributes.** Tuples are records `{a: int, b: string}`. Schemas
  are runtime values (column name + type lists), not lifted into OCaml's
  static type system. Operators validate schema compatibility at runtime.
- **No implicit NULLs; no three-valued logic.** Nullability is opt-in per
  column via `option` types. Predicates are two-valued. SQL's three-valued
  semantics are translated into explicit `option` handling by the SQL
  compiler. Outer joins are schema-transforming operators: their result
  schemas have the unmatched side's columns lifted to `option`.
- **Value types for v1**: `int64`, `string`, `bool`, plus `option` of each.
  Decimal, date/time, float, blob, and JSON are deferred — each is a
  contained future addition.

### Execution model

- **Volcano (pull-based) via `Seq.t`.** An RA operator is a function
  shaped roughly `Relation.t -> Relation.t`, where `Relation.t` carries a
  schema, a set/bag tag, and a `tuple Seq.t`. Demand-driven, streaming for
  free, blocking operators (sort, hash-join build, group-by, distinct)
  materialize explicitly.
- LMDB cursors wrap as `Seq.t` for table scans and index scans.

### Storage layout

- **Index-organized tables.** Each table's primary key is the LMDB key;
  the value is the rest of the tuple. PK lookups and PK range scans are
  one B+tree descent. Tables without a user-supplied PK get a synthetic
  auto-increment PK.
- **One LMDB subDB per table**, plus one for the catalog, plus one per
  secondary index. `MDB_dbs` set generously at env open.
- **Secondary indexes** are subDBs with composite keys
  `(indexed_columns, primary_key)` and empty values. Lookup is a prefix
  scan yielding PKs; PKs point-lookup back into the table.
- **Byte-comparable key encoding**: `int64` as sign-flipped big-endian,
  `string` as UTF-8 length-prefixed (when composite), `bool` as one byte,
  `option` as discriminator byte plus payload. Composite keys length-
  prefix variable-length parts so prefix comparison is sound.

### IR architecture

The compiler stack has three layers, with two frontend ASTs lowering to
two algebraic IRs.

```
   SQL source                           RA source
       ↓                                    ↓
   SQL parser                           RA parser
       ↓                                    ↓
   SQL AST                              RA AST
       ↓ (heavy lowering: SELECT-FROM-     ↓ (light lowering: mostly
       WHERE-GROUP-HAVING-ORDER, NULLs,    desugaring set/bag,
       subqueries become algebra)         resolving names)
       ↓                                    ↓
                  Logical IR (algebra)
                          ↓
                  Logical → Physical
                  (trivial in v1; gets
                  smarter when the
                  optimizer arrives)
                          ↓
                  Physical IR (executable)
                          ↓
                  Engine evaluates
```

- **Two frontend ASTs**, because the two languages have meaningfully
  different surface concepts (especially SQL's `SELECT-FROM-WHERE-GROUP-BY-
  HAVING-ORDER-BY` shape) and we want each parser to faithfully preserve
  source structure for error messages and round-tripping.
- **Two algebraic IRs from day one** — even with no optimizer in v1.
  Logical IR holds pure algebra (`Scan`, `Select`, `Project`, `Join`).
  Physical IR holds execution choices (`FullScan`, `IndexScan`,
  `NestedLoopJoin`, `HashJoin`, `Sort`, `Limit`). The v1 logical→physical
  translation is mechanical and trivial — its purpose is to make the
  layering visible and to prepare the ground for a real optimizer later.
- **Optimizer is deferred.** When it arrives (probably after the SQL
  frontend exists and we have meaningful workloads to optimize), it
  becomes two phases: logical rewrites first (predicate pushdown, join
  reordering, projection pushdown), then implementation selection during
  logical→physical translation.

### Surface RA query language

- **Pipeline syntax with ASCII keywords.** Reads in dataflow order.
  Composable. Trivial to parse. Differentiates strongly from SQL.
- Sketch of intended surface across the operator set:

  ```
  users | select age > 21 | project name, email
  users | join orders on users.id = orders.user_id
  users | join orders using user_id
  users | project name, age + 1 as next_age
  users | distinct
  users | union others
  users | rename name as full_name
  users | aggregate by department: count(*), avg(salary) as avg_pay
  users | sort age desc | limit 10
  ```

- Predicate sublanguage: comparisons (`=`, `<`, `<=`, `>`, `>=`, `<>`),
  boolean `and`/`or`/`not`, literals, column references (qualified after
  joins).
- `option`-aware predicate handling is explicit. Sugar to be designed
  when the slices need it.

### DDL and DML

- **Deferred.** Early slices use hardcoded LMDB fixtures (a small piece
  of OCaml code that creates a table and populates it directly through
  the storage layer).
- The shape of DDL/DML is left open: REPL meta-commands above both
  languages, RA-language extensions, SQL-only DDL/DML, or some
  combination. Decided when a slice forces it.

## Slice plan

Build vertical slices, each end-to-end and demoable. The first few are
firm; later ones are sketches and will evolve.

- **Slice 1** — Scan a table via the RA language. Hardcoded fixture
  creates a table on disk. RA parser handles a bare relation name.
  Logical `Scan`. Physical `FullScan`. Engine evaluates by opening an
  LMDB cursor wrapped as `Seq.t`. REPL prints tuples.

  Layers built at minimum: byte-comparable encoding for v1 types,
  catalog read, table cursor, `Relation.t`, logical and physical IRs (one
  node each), trivial translation, RA parser (one production), REPL.

- **Slice 2** — Selection (`σ`). Predicate sublanguage at its smallest:
  comparisons against literals on the row's columns. No predicate
  pushdown (no optimizer yet).
- **Slice 3** — Projection (`π`). Schema rewriting. The set/bag type
  machinery makes its first appearance: `π` downgrades to `Bag`.
- **Slice 4** — Cross product and inner join (nested-loop). First
  multi-relation query. Predicate sublanguage gets qualified column
  references.
- **Slice 5** — Primary-key range scans (`IndexScan` physical operator).
  First time the physical IR has a real choice; logical→physical picks
  `IndexScan` over `FullScan` when the predicate is a PK range.
- **Slice 6** — Secondary indexes. Catalog grows. Index maintenance on
  fixture insertion. `IndexScan` on a secondary index.
- **Slice 7** — `distinct`, `union`, `intersect`, `difference`. Set/bag
  type machinery does real work.
- **Slice 8** — Minimal SQL frontend: `SELECT cols FROM table WHERE pred`,
  single table, no joins yet. SQL AST, SQL→logical lowering for the
  basic shape. `option`-aware predicate translation for `IS NULL` etc.
- **Slice 9** — SQL joins (inner only).
- **Slice 10** — Aggregation operator (`γ`) and SQL `GROUP BY` /
  `HAVING`.
- **Beyond** — outer joins, sort/limit, DML (probably SQL-side first),
  DDL (probably SQL-side first), more types, optimizer. Order TBD based
  on what's learned from earlier slices.

Each slice gets its own follow-on plan document (`02-…`, `03-…`)
detailing sub-steps, with TDD where appropriate, review and commit at
sensible boundaries.

## Deferred decisions

To revisit when slices force them:

- Error handling style (`result` vs exceptions; how parse/runtime errors
  surface in the REPL).
- Optimizer architecture (rule-based first; cost-based later; where
  statistics live).
- Transaction model exposed to the user (LMDB gives them; we choose how
  to surface them).
- Full SQL type system (decimal, date/time, blob, JSON).
- DDL and DML form (REPL meta-commands, in-language operators, SQL-only).
- Project module layout — let it emerge from the first few slices.
- Testing tooling (Alcotest vs expect-tests vs other) — pick when slice 1
  needs it.
- Concurrency beyond LMDB's defaults.
