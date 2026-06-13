# Query lifecycle

One query, traced from the characters the user types to the rows that
come back. [architecture.md](architecture.md) names the layers and
draws the pipeline; this doc walks a single query through every one of
them, showing the value at each stage. The query is deliberately
small — a scan, a filter, and a projection — so each transformation is
legible:

```
users | restrict active | project name
```

> **These examples are hand-checked, not doctested.** The logical and
> physical plans below are captured verbatim from the binary run with
> `--show-logical --show-physical`; the AST and the intermediate prose
> are written by hand against the source. The project's doctest harness
> verifies REPL transcripts, but it runs *without* the `--show-*`
> flags, so it cannot check a plan dump. Treat this page as
> documentation that a human keeps honest, not as machine-verified
> output — if the plan printers change shape, this page needs a manual
> refresh. To reproduce the captures:
>
> ```
> $ printf 'users | restrict active | project name\n' \
>     | dovetail --demo-data --show-logical --show-physical /tmp/play
> ```

The walkthrough reads against the demo `users` table
(`dovetail --demo-data`), whose type is:

```
(users.id: int64, users.name: string, users.email: string,
 users.active: bool, primary key (id))
```

## 1. Text → AST

The RA [`Parser`](../../lib/surface_ra/parser.mli) (built on
`angstrom`) turns the query text into a surface
[`Ast.t`](../../lib/surface_ra/ast.mli). The AST mirrors the syntax
one-for-one: each `|` stage becomes a node wrapping the stage to its
left, so the pipeline nests inside-out. There is no `--show-ast` flag;
the shape, written out, is:

```ocaml
Project {
  input = Restrict {
    input = Relation_name "users";
    predicate = Column { qualifier = None; name = "active" };
  };
  columns = [ { qualifier = None; name = "name" } ];
}
```

The parser knows nothing about whether `users` exists, whether
`active` is a column, or whether it is boolean. Those are questions
about meaning, and the AST is purely about syntax — every node
corresponds to something the user typed and nothing more.

## 2. AST → logical plan

[`Lower`](../../lib/surface_ra/lower.ml) converts the surface AST into
a [`Logical.t`](../../lib/plan/logical.mli) — the relational algebra
that describes *what* the query computes. The structure is nearly
one-to-one here (`Relation_name` → `Scan`, `Restrict` → `Restrict`,
`Project` → `Project`), but the vocabulary shifts from syntax to
algebra: a `Scan` is "read every row of this table", independent of how
the bytes are laid out, and the predicate becomes a `core`
[`Expression.t`](../../lib/core/expression.mli) shared by both
surfaces. `--show-logical` prints the result as an indented tree, leaf
at the bottom:

```
Project(name)
  Restrict(active)
    Scan(users)
```

Both surface languages lower to this same IR; from here down nothing
knows or cares whether the query arrived as RA or SQL.

## 3. Typecheck

[`Typecheck`](../../lib/plan/typecheck.mli) validates the logical plan
against a **catalog snapshot** — the table kinds read inside the same
read transaction evaluation will later use, so the schema cannot shift
between checking and running. It walks the tree accumulating every
error in one pass, and for our query it confirms:

- `Scan(users)` — `users` exists in the catalog.
- `Restrict(active)` — the column `active` resolves to exactly one
  field of the scan's row kind, and that field is `bool`, so it is a
  valid predicate. (A non-boolean predicate, or an unknown column,
  would be the error reported here.)
- `Project(name)` — `name` resolves to exactly one field of the
  filtered relation's row kind.

The pass **returns the plan unchanged on success.** There is no
separate typed IR today: `typecheck` is `Logical.t -> (Logical.t, error
list) result`, and the success arm hands back the very `Logical.t` it
was given. (The design sketch of a `Typed_logical.t` GADT in
[`design/ir-types.md`](../design/ir-types.md) is a proposal, not the
as-built shape.) So the value flowing into the next stage is
byte-identical to the tree from stage 2 — typecheck is a gate, not a
transform.

## 4. Logical plan → physical plan

[`Translate`](../../lib/plan/translate.ml) lowers the logical algebra
into a [`Physical.t`](../../lib/plan/physical.mli) — the concrete
execution strategy. This is where "what" becomes "how", and the
operator names change to reflect it:

```
Project(name)
  Filter(active)
    FullScan(users)
```

- `Scan` → **`FullScan`** — read every row by opening a cursor over the
  table's storage subDB and walking it in primary-key order. Translate
  picks `FullScan` because the predicate doesn't pin the primary key; a
  `restrict id = 5` would instead become an `IndexLookup`, and a join
  on a PK would become an `IndexedNestedLoopJoin`. Those rewrites, and
  the invariants that keep them faithful, are in
  [optimization.md](optimization.md).
- `Restrict` → **`Filter`** — the executor's name for the same
  row-keeping operation. Kind and set/bag multiplicity pass through
  unchanged.
- `Project` stays `Project`, but note its physical contract: dropping
  columns can introduce duplicates, so projection **downgrades the
  result to a bag** and empties the primary key.

## 5. CPS evaluation

[`Eval`](../../lib/execution/eval.mli) executes the physical plan. The
shape that matters most here is that evaluation is in
**continuation-passing style**: `eval` takes a continuation and calls
it with the result *term*, rather than returning one. This is forced by
storage — a `FullScan` produces a lazy row sequence pulling from a live
LMDB cursor, valid only inside the cursor's scope, so the consumer must
run *inside* that scope rather than receiving a relation that would
outlive it. The full argument is in [executor.md](executor.md); the
transaction-and-cursor lifetime it rests on is in
[storage.md](storage.md).

For our query the continuations nest bottom-up. The REPL asks
`Logical.required_access` whether the plan writes (it doesn't), opens a
**read** transaction, and evaluates inside it:

1. `FullScan(users)` opens a cursor and yields the table's rows as a
   one-shot `Seq.t`, in primary-key order.
2. `Filter(active)` wraps that sequence, evaluating the `active`
   expression against each row and passing through the ones where it
   holds.
3. `Project(name)` maps each surviving row to just its `name` field.
4. The top continuation collects the projected rows into a
   `Term.Relation_value`.

Everything stays lazy and single-pass: rows stream from the cursor
through filter and projection without the whole table ever being
materialised.

## 6. Rendered relation

The terminal [`Term.t`](../../lib/core/term.mli) is formatted back to
text. On the RA surface that is the relation-literal form — the same
syntax a user could type back in as input:

```
relation (users.name: string) {
  (users.name = "Alice"),
  (users.name = "Carol"),
  (users.name = "Dave")
}
```

Three of the demo table's users are active. The result kind is
`(users.name: string)` — a single column, no primary key (projection
dropped it), carried all the way from the `FullScan`'s full row kind
through the two narrowing operators above it.

(The SQL surface would render the same term through `Sql_table` as an
aligned psql-style table instead; see
[sql-frontend.md](sql-frontend.md). The term is identical — only the
presentation differs.)
