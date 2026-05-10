# Dovetail

A small relational database in OCaml, built on top of LMDB. Two query
languages (a pipeline-style relational-algebra language, and SQL on top)
sit over a Volcano-style executor and a hand-rolled storage layer.

This is a learning vehicle, not production software. The plan deliberately
delivers the system as thin vertical slices — each slice adds one
operator's worth of code at every layer, end to end. See
[`docs/plans/01-initial-plan.md`](docs/plans/01-initial-plan.md) for the
foundational design and the slice plans (`02-...`, `03-...`) for the work
in flight.

## Layer diagram

The query pipeline runs top-to-bottom from text to tuples and back to text.
The storage stack sits below it, used by `Eval` and the catalog.

```
  Query pipeline                                  Storage stack
  ──────────────                                  ─────────────

      "users"
         │
         │  Parser   (angstrom; slice 1 step 8)
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

`Fixture` sits beside `Catalog` and the storage stack, populating a
hardcoded `users` table on first run. Once DDL/DML lands in a later
slice it goes away.

## Layers

### Query pipeline

| Layer       | Type                                     | Role                                                                                           |
| ----------- | ---------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `Parser`    | `string -> (Ast.t, error) result`        | Surface syntax → AST. Slice 1 only handles bare identifiers.                                   |
| `Ast`       | `t = Relation_name of string \| ...`     | What the user typed, structured. No semantics yet.                                             |
| `Lower`     | `Ast.t -> Logical.t`                     | Replace each syntactic node with the algebraic operator it denotes.                            |
| `Logical`   | `t = Scan of {...} \| ...`               | Algebra: *what* the query computes, with no execution detail.                                  |
| `Translate` | `Logical.t -> Physical.t`                | Pick a physical strategy per operator. Future home of optimisation.                            |
| `Physical`  | `t = FullScan of {...} \| ...`           | Concrete execution plan: cursors, hash joins, etc.                                             |
| `Eval`      | `env -> txn -> Physical.t -> Relation.t` | Volcano executor. Each operator returns a `Relation.t` whose `tuples` seq is pulled lazily.    |
| `Relation`  | `'tag t = { schema; tuples }`            | Schema-tagged stream of tuples. Phantom `'tag` distinguishes set vs bag semantics.             |

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

## Building and running

OCaml 5.2 in a local opam switch at the repo root.

```sh
opam exec -- dune build              # compile
opam exec -- dune test               # run all alcotest suites
opam exec -- dune build @fmt --auto-promote   # format
opam exec -- dune exec dovetail      # run the binary (slice 1 step 9 onward)
```

See [`CLAUDE.md`](CLAUDE.md) for project-specific naming and tooling
conventions.
