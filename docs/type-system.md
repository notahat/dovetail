# Type system

A design note, not a plan. It commits to a surface syntax for the
ladder of values and types Dovetail already organises its core around
— Scalar, Row, Relation, Catalog — and folds DDL into the same
pipe-style language the surface RA already uses.

Pairs with:

- [`literals-as-a-ladder.md`](literals-as-a-ladder.md), which frames
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

Dovetail's core already organises everything as types and values at
four rungs: Scalar, Row, Relation, Catalog. The query language already
composes operators through `|`. The DDL surface — a separate `:`-sigil
grammar with its own AST — is the one place that doesn't fit. This
note describes a syntax in which the ladder is a first-class part of
the language, types are values that flow through pipes, and DDL
becomes ordinary pipe-stages over them.

The move is *not* "invent a pipe syntax." It is "extend the pipe
syntax that already exists in `lib/surface_ra/parser.ml` so that
types, rows, relations, and catalog operations live inside it instead
of beside it."

## The pipe is already there

A quick orientation, because the move below leans on what the
existing parser does:

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
- `insert into …` is a regular pipe operator that happens to terminate
  a pipeline (the parser rejects anything after it). It produces a
  one-row `(insert_count: int64)` relation, so downstream eval and
  printing don't need a separate "mutation" universe
  (`parser.ml`'s `insert_sink` / `pipeline_parser`).

DDL is the exception: a `:`-sigil grammar with its own AST
(`lib/ddl/statement.ml`), its own executor (`Ddl_executor`), and a
canonical-form printer that round-trips with the DDL parser
(`lib/ddl/format.ml`). It does not pass through Lower / Translate /
Physical / Eval. The REPL classifies a parsed top-level into either
"pipeline" or "DDL statement" and dispatches accordingly.

The aim is to remove that fork.

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
of `users` — the same output `:describe users` produces today.

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
- **`catalog | tables`** is the new spelling for `:list tables`. It is
  a projection on the catalog record — "give me the field names" —
  one rung up from `users | project name`. It is *not* a relation
  operation; it returns a list, the same way the old DDL surface did.
- **`insert into`** already exists and is unchanged. It accepts a
  relation as upstream (existing) and now also a single row literal
  (new — falls out of rows being first-class).

## How the existing DDL surface maps over

The DDL universe today is exactly three statements (see
`lib/ddl/statement.mli`); a fourth, `:describe`, was retired once the
`| type` operator landed and now lives only as a pipe stage:

| Existing DDL                                                | Pipe-form replacement                                                |
|-------------------------------------------------------------|----------------------------------------------------------------------|
| `:list tables`                                              | `catalog \| tables`                                                  |
| `:create table users (id: int64, …) primary key (id)`       | `(id: int64, …, primary key (id)) \| create table users`             |
| `:drop table users`                                         | `drop table users`                                                   |

`| type` is already built — `users | type` prints the relation type
that `:describe users` used to print, up to spelling differences
(`int64` lowercase, `:` between name and type). The remaining
pipe-form replacements above are the design target; the `:`-sigil
statements are what the parser dispatches to today.

Once this is built, `lib/ddl/` becomes dead code: no `:`-sigil
grammar, no `Ddl.Statement.t` AST, no `Ddl_executor`, no
`Ddl.Format`. The pipe parser absorbs the full surface and dispatches
to catalog-mutating sinks the same way it dispatches to
relation-mutating ones today.

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
- **Qualifiers on row fields.** `Row.field` carries an optional
  qualifier (table alias) used inside multi-relation expressions. The
  canonical form above drops qualifiers — only the field name and
  type round-trip. Stored types in the catalog do not carry
  qualifiers either; qualifiers are a query-construction concept,
  not a stored-shape one. If a context emerges where round-tripping
  *with* qualifiers matters, a `users.id: int64` form is the obvious
  extension.

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
