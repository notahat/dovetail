# Type system

Reference for Dovetail's surface syntax across the ladder of values and
types its core organises — Scalar, Row, Relation, Catalog — and the
single pipe-style language that covers them all.

Pairs with:

- [`literals-as-a-ladder.md`](../archive/literals-as-a-ladder.md), which frames
  the ladder conceptually and sketches a speculative
  math-RA-flavoured syntax. This note supersedes that speculative
  sketch — the framing it captures is exactly what's committed to
  here, but the surface details land differently because Dovetail's
  existing language is pipe-shaped, not brace-shaped.
- [`type-ladder.md`](type-ladder.md), which describes the as-built
  shape per rung in `lib/core/`.

## A note on vocabulary

The surface language uses **type** for what `type-ladder.md` and the
OCaml code call **kind**. They are the same concept — the static
shape of a value, with no payload — under two names.

The split is forced by OCaml. `type` is a keyword in the host
language, so the code has to call its own type-shaped identifiers
something else; `kind` is the convention `lib/core/` settles on
(`Scalar.kind`, `Row.kind`, `Relation.kind`). A user typing at the
REPL has no such constraint, and "what's the type of this column" is
what they would actually say.

This note uses "type" in prose and as the operator name, and "kind"
only when referring to specific OCaml identifiers. `ubiquitous-
language.md` should grow an entry pinning down the duality once this
syntax lands.

## The premise

Dovetail's core organises everything as types and values at four rungs:
Scalar, Row, Relation, Catalog. The query language composes operators
through `|`, and the ladder is a first-class part of it: types are
values that flow through pipes, and catalog mutation is ordinary
pipe-stages over them.

## How the pipe works

- `|` is the only composition operator. It is left-associative; each
  step is a function from the upstream relation to a new one
  (`parser.ml`'s `pipeline_step` / `query_pipeline`).
- A bare query in the REPL is evaluated and printed. There is no
  explicit print step; results render automatically
  (`repl.ml`'s `evaluate_and_print` / `print_result`).
- Evaluation streams end-to-end. `Relation.value` is a lazy `Seq.t`;
  `Filter` and `Project` wrap with `Seq.filter` / `Seq.map`;
  `FullScan` opens a live cursor. Pipelines compose without
  intermediate materialisation (`lib/execution/eval.ml`).
- `insert into …`, `create table …`, and `drop table …` are regular
  pipe operators that happen to terminate a pipeline (the parser
  rejects anything after them). They produce a one-row result relation
  (`insert_count`, `created`, `dropped`), so downstream eval and
  printing don't need a separate "mutation" universe
  (`parser.ml`'s `insert_sink` / `pipeline_parser`).

## Syntax at each rung

Two patterns recur:

- `name: type` binds a label to a type. Used in row types, relation
  types, catalog types.
- `name = value` binds a label to a value. Used in row values,
  relation values (rows inside a relation literal), catalog values.

Same parens-and-comma machinery, different right-hand side. The
distinction is the same one OCaml records use (`{ x : int }` versus
`{ x = 1 }`) and lets a reader tell type from value at a glance.

### Scalar

**Type** — one of three lowercase keywords:

```
int64    string    bool
```

**Value:**

```
42        -42       0
"hello"   ""
true      false
```

`Scalar.format` in `lib/core/scalar.ml` already prints values in this
form. The type-side spellings (`int64` etc.) replace the current
DDL-side capitalised forms (`Int64`).

### Row

**Type** — parenthesised list of `name: type` bindings:

```
(id: int64, name: string, active: bool)
()                                          -- empty row type
```

**Value** — parenthesised list of `name = value` bindings:

```
(id = 1, name = "alice", active = true)
()                                          -- empty row
```

Rows are self-describing. A row standing alone carries its own field
names, the same way a row type standing alone carries its own field
types. This means a row can flow through a pipe without an external
schema: `(id = 1, name = "alice") | insert into users` is
self-contained.

Inside a relation literal, rows are still self-describing — same
syntax everywhere for v1. A positional row syntax (where the
relation's header supplies names) is plausible later but deliberately
deferred; consistency wins for the first cut.

### Relation

**Type** — row type, optionally with refinement clauses interleaved:

```
(id: int64, name: string)
(id: int64, name: string, primary key (id))
```

Refinements are clauses in the same parenthesised list as the field
declarations. `primary key (...)` is the only one today; future
refinements (`unique (...)`, `check (...)`, …) slot into the same list
as additional clause keywords. A row-type parse rejects refinements;
a relation-type parse accepts zero or more.

**Value** — a relation literal carries its type explicitly:

```
relation (id: int64, name: string) {
  (id = 1, name = "alice"),
  (id = 2, name = "bob"),
}

relation (id: int64, name: string) {}        -- empty
```

The leading `relation` keyword opens the literal; its type appears
inside the parens; its rows appear inside the braces, each a row
literal, comma-separated, with a permitted trailing comma. The type
is explicit so empty relations are still typed.

### Catalog

A catalog is a record of named relations plus cross-table refinements.
The single-catalog model — Dovetail has exactly one catalog per
database, exposed as the bare name `catalog` — is the only one
supported. Multi-catalog and a `create database` form may arrive
later; the syntax below leaves room for them but does not commit.

**Type** — record of `name: relation-type` bindings, with
cross-table refinement clauses interleaved:

```
catalog {
  users: (id: int64, name: string, primary key (id)),
  orders: (id: int64, user_id: int64, primary key (id)),
  foreign key (orders.user_id references users.id),
}
```

**Value** — same shape with `=` and relation values:

```
catalog {
  users = relation (id: int64, name: string) {
    (id = 1, name = "alice"),
  },
  orders = relation (id: int64, user_id: int64) {
    (id = 100, user_id = 1),
  },
}
```

Foreign keys, cross-table check expressions, and future cross-table
refinements live in the catalog type, not in the individual relation
types. This is the placement `literals-as-a-ladder.md` argues for: a
foreign key talks about two relations, so it belongs at the rung
where both are visible.

## The `type` operator

`type` is a pipe stage that returns the type of whatever flows into it:

```
42 | type                              → int64
(id = 1, name = "alice") | type        → (id: int64, name: string)
users | type                           → (id: int64, name: string, primary key (id))
catalog | type                         → catalog { users: (…), orders: (…), … }
```

It works at every rung. The REPL prints whatever falls out the end of
the pipeline, so `users | type` typed alone renders the relation type
of `users`.

`type` applied to a type is an error: `(id: int64) | type` fails with
"type: input is already a type." The system has no notion of "types
of types." If a use case for a meta-type appears, the rule can be
revisited; today nothing wants one.

## Pipe stages across the ladder

What flows into what:

| Source                | Pipe stage                       | Output                                           |
|-----------------------|----------------------------------|--------------------------------------------------|
| any                   | `type`                           | the type of the input                            |
| relation              | `filter (...)`                   | relation (streaming)                             |
| relation              | `project (...)`                  | relation (streaming)                             |
| relation              | `cross …`                        | relation                                         |
| relation              | `join … on …`                    | relation                                         |
| relation              | `insert into <name>`             | one-row `(insert_count: int64)` relation         |
| row                   | `insert into <name>`             | one-row `(insert_count: int64)` relation         |
| relation-type         | `create table <name>`            | write-result                                     |
| relation              | `create table <name>`            | write-result (seeds rows after create)           |
| catalog               | `tables`                         | list of table names                              |
| (no source)           | `drop table <name>`              | write-result                                     |

Some things to note about that table:

- **`drop table <name>`** takes the table name as part of its
  keyword, not as a piped value. It is a sink that mutates the
  ambient catalog; it has no upstream input. This keeps the
  catalog-name handling symmetric between `create table` and
  `drop table`: both name the table in their keyword, and content
  (when any) flows in from the left.
- **`create table <name>`** accepts either a relation-type or a
  relation-value. A type creates an empty table of that shape; a
  value creates the table *and* seeds it with the rows. This is one
  operator with two arities at the input rung, not two operators.
- **`catalog | tables`** is a projection on the catalog record — "give
  me the field names" — one rung up from `users | project name`. It
  is *not* a relation operation; it returns a one-column
  `(name: string)` relation of every table in the catalog.
- **`insert into`** accepts a relation as upstream and also a single
  row literal (the latter falls out of rows being first-class).

## Catalogs

The catalog value is a fully-populated value at the surface: bare
`catalog` typed in the REPL renders every table's rows, scoped to a
single read transaction with lazy cursors. The single-catalog model
holds — Dovetail has exactly one catalog per database — and a
`create database` form and multi-catalog support are not committed.

## Qualifiers

`Row.field` carries an optional qualifier — a table alias that
distinguishes `users.id` from `orders.id` inside a multi-relation
query. Joins and cross-products produce them; stored catalog types
never carry them. The canonical syntax extends the `name: type` and
`name = value` forms with a `qualifier.name` head:

```
(users.id: int64, orders.user_id: int64)
(users.id = 1, orders.user_id = 1)
```

The rule is that qualifiers round-trip exactly. A qualified field
never silently loses its qualifier; an unqualified field never
silently gains one. Display and input agree everywhere a row, row
type, or relation type appears.

### How operators handle qualifiers

- **`filter`, `project`** preserve whatever qualifiers are on the
  input. Expressions inside them accept bare field names when the
  reference is unambiguous, and require a qualified name
  (`users.id`) when two input fields share a name. The qualifier
  exists to disambiguate; demanding it where there is nothing to
  disambiguate would be noise.
- **`join`, `cross`** produce qualified output. The surface RA
  already attaches qualifiers internally; the canonical formatter
  now prints them.
- **`insert into <name>`** and **`create table <name>`** are the
  boundary into stored shapes. Stored types have no qualifiers, so
  both reject qualified input rather than silently stripping. A
  qualified field reaching one of these sinks almost always means
  the upstream pipeline picked up the wrong rows; failing loudly is
  safer than guessing. Matching qualifiers (`(users.id = 1) | insert
  into users`) are rejected on the same grounds — the no-silent-drop
  rule does not have a "but it matched" escape hatch.

To bridge a qualified pipeline into a stored shape on purpose, an
explicit stripping stage sits between them:

```
users
| join orders on users.id = orders.user_id
| unqualify
| insert into joined
```

`unqualify` is a pipe stage that drops every field's qualifier. It
accepts either a relation or a row. It fails if stripping would
collide two fields onto the same name — for instance, the output of
`users | join orders …` contains both `users.id` and `orders.id`,
and `unqualify` on that relation is an error. Resolving the
collision is the caller's job: a `project` upstream that drops or
renames one of them is the usual move.

### Qualifiers in literals

Row and relation literals may be written with qualified fields
(`(users.id = 1, users.name = "alice")`, or a relation literal whose
declared type is qualified). This is mostly useful for tests and for
round-tripping pipeline output; it has no effect on storage. A
qualified literal fed into `create table` or `insert into` follows
the sink rules above.

## What this leaves open

A handful of questions the syntax above does not commit on. They are
worth naming explicitly so the design conversation has somewhere to
land them as they come up.

- **Pipe stages for value and value-type sources.** Nothing in the
  current operator zoo consumes a bare value or value-type from the
  left of a pipe. They exist in the grammar and round-trip, but
  `42 | something` has no defined `something` today. Possibly forever;
  possibly an arithmetic / cast operator family eventually. Not
  committing.
- **Pipe stages for catalog-mutation beyond create/drop.** `alter
  table` (rename, add column, change column type, change primary
  key, …) is not in scope. When it arrives, the natural shape is a
  family of catalog-mutating sinks (`rename table`, `add column`, …)
  parallel to `create table` / `drop table`. The catalog literal
  would also support being treated as a value the planner can diff
  against — the migration story `literals-as-a-ladder.md`
  anticipates — but that is two design notes away.
- **String escapes.** The current parser doesn't handle escape
  sequences in string literals; a string containing `"` doesn't
  round-trip. Orthogonal to the syntax described here, but worth
  flagging because the "everything round-trips" framing depends on
  the value-literal parser eventually getting there.
- **Bag vs set semantics in relation literals.** Dovetail's relations
  are bag-tagged today; `Relation.t` carries a `[`Bag | `Set]`
  phantom. The literal syntax above does not distinguish. The default
  is "bag" — duplicate rows are preserved as written — matching the
  rest of the system; an explicit set form is not needed for v1 but
  may want a marker later.

## What this note is not

- Not a plan. The implementation order, the deletion timeline for the
  existing DDL surface, and any parser-level details are out of
  scope. A slice plan will follow and reference this note.
- Not a claim that every rung is fully fleshed out. The catalog rung
  in particular is committed only at the level of read-side syntax
  (`catalog`, `catalog | type`, `catalog | tables`) and the
  individual table-mutation sinks. A full catalog *literal* on the
  left of a pipe — `catalog { … } | create database mydb`, say —
  is sketched but not committed; it lives beyond single-catalog
  support.
- Not a replacement for `literals-as-a-ladder.md`. The ladder framing
  there is the *why*; this note is the *what does the syntax look
  like, concretely*. The two are meant to be read together.
