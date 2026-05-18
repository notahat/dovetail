# DDL in the RA query language

This document captures the design of data-definition operators
(`create table`, `drop table`, `describe`, `list tables`) in the surface
RA query language. All four are designed together so the surface is
coherent, and so the shape of `create table` isn't quietly determined
by the cases it doesn't have to handle. Which subset lands in any
particular slice is a slice-plan decision, not a design-doc decision.

This is a design document, not a slice plan. It is parallel in form
and intent to [`docs/plans/dml-design.md`](dml-design.md), which
covers `insert`, `update`, and `delete`.

## Scope

In scope here:

- Surface syntax for `create table`, `drop table`, `describe`, and
  `list tables`.
- A DDL-statement sigil that distinguishes catalog operations from
  pipelines at top of input.
- The round-trip property that ties `describe`'s output to `create
  table`'s input.
- The shape of the new `Ddl` module and how it slots into the
  existing pipeline (parse → lower → translate → eval → render).
- The transaction and storage-lifecycle model.

Out of scope here, mentioned only as context:

- `alter table` (add/drop/rename column, change PK, change kind) — a
  separate design exercise. With no nulls and no defaults, "add
  column to a non-empty table" has no off-the-shelf answer; it
  deserves its own design doc.
- `create index` / `drop index` — presupposes secondary indexes as
  a user-visible concept, which don't exist yet.
- `rename table`, `truncate table` — deferrable trivia. Slot in
  alongside the existing DDL statements when needed.
- `if not exists` / `if exists` idempotency clauses — pure
  ergonomics, additive when scripts become a real story.
- Multi-statement input and explicit `begin` / `commit` / `rollback`
  — already on the Beyond list, shared with DML.
- System-tables-style queryable introspection (`pg_catalog` /
  `information_schema`) — a legitimate future direction, but the
  immediate need is inspection, not relational composition of
  metadata.

## Conceptual model

The DML design framed the surface language around two universes of
first-class values: **relations** (composed in pipelines) and
**scalars** (composed in expressions). DML lives in pipeline position
because rows are the thing that flows. Queries take relations in;
mutations are pipeline sinks that take relations in and produce side
effects.

DDL doesn't fit that frame, and shouldn't be made to. `create table`
doesn't consume a relation — there's no relation flowing in. `drop
table` doesn't either. `describe` and `list tables` produce output,
but the output isn't a relation; it's catalog metadata rendered
directly.

So DDL is a **third universe**, deliberately separated:

- **Pipelines** (queries and DML) — relations flowing through
  operators, composed with `|`.
- **DDL statements** — catalog and table-lifecycle operations, with
  no composition. Each statement is a single, complete operation.

The separation is honest: catalog manipulation and relational data
processing are different kinds of work, and the language reflects
that. The cost is one extra top-level grammar branch; the benefit is
that nothing about pipelines has to bend to accommodate the
asymmetry, and nothing about DDL has to dress up as relational.

This frame retroactively justifies several decisions:

- DDL appears in its own top-level grammar position, not as a
  nullary-upstream pipeline sink.
- DDL has its own module (`lib/ddl.ml`), not constructors inside
  `Logical.plan`. The implementation mirrors the surface split.
- `describe` prints text matching the `create table` form, rather
  than returning a relation that the user composes with `restrict`.
  Inspection lives in the DDL universe because the catalog lives
  there.

## Top-of-grammar shape

```
program       := pipeline | ddl_statement
pipeline      := relation_expr ("|" pipeline_op)*               -- existing
ddl_statement := ":" ddl_body
ddl_body      := "create" "table" identifier column_list pk_clause
              |  "drop"   "table" identifier
              |  "describe" identifier
              |  "list" "tables"
column_list   := "(" column_decl ("," column_decl)* [","] ")"
column_decl   := identifier ":" kind
pk_clause     := "primary" "key" "(" identifier ("," identifier)* [","] ")"
kind          := "Int64" | "String" | "Bool"
```

The sigil `:` is the only top-of-input mark of a DDL statement. The
parser dispatches on it: a leading `:` switches to DDL parsing;
anything else parses as a pipeline. The DDL keywords (`create`,
`drop`, `describe`, `list`) are **not** globally reserved — inside
any pipeline, expression, or column-list position they're regular
identifiers. The sigil is what reserves them, and only at top of
input.

The contextual keywords inside DDL (`table`, `tables`, `primary`,
`key`) appear in fixed grammatical positions where the parser expects
a literal, so they aren't competing with identifier slots at all. You
can name a column `primary` or `key` or `table` and the parser will
be happy.

`Int64`, `String`, and `Bool` are parsed as identifiers at the kind
position, then matched against the known set. An unknown name there
is a validation error naming the offending token.

## The sigil

The choice to mark DDL with `:` rather than reserve the lead keywords
globally has three justifications:

1. **Visual separation matches the conceptual separation.** DDL is
   in its own universe; the sigil makes that visible at every call
   site. A reader scanning a session can tell at a glance whether a
   line is data manipulation or catalog manipulation.
2. **Zero global reservation.** Without a sigil, every DDL lead
   keyword (`create`, `drop`, `describe`, `list`, and future
   additions like `alter`, `rename`, `truncate`, `explain`) would
   become unusable as a bare top-of-input table reference. The sigil
   bounds the surface cost to a single character.
3. **Precedent.** `:` is the established convention for "command
   mode" or "directive" operations in editor-language families
   (vim, ex, sam, less). It reads as terse and intentional rather
   than as a control code — different in register from `.` (file
   extensions, SQLite meta-commands) or `/` (paths, chat commands).

The sigil overloads `:`, which dovetail already uses **infix** in
named pairs (`{id: 7, name: "x"}`) and column declarations (`id:
Int64`). The two uses are positionally distinct: prefix at top of
input versus infix between an identifier and what follows. Both the
parser and the eye disambiguate them on rhythm.

The sigil is part of the DDL surface, not a REPL meta-command. It
appears in `describe` output so that round-tripped text is literally
re-executable.

## Create table

```
:create table users (
  id: Int64,
  name: String,
  email: String,
  active: Bool,
) primary key (id)
```

Compound key:

```
:create table order_items (
  order_id: Int64,
  product_id: Int64,
  quantity: Int64,
) primary key (order_id, product_id)
```

Decisions:

- **Paren `()` around the column list, not brace `{}`.** Brace would
  suggest a "schema literal" sublanguage parallel to relation
  literals. Schemas only appear in one place (the `create table`
  body) and don't earn sublanguage status; paren is the neutral
  choice for "ordered list of typed declarations".
- **`name: Kind` for column declarations.** The colon-separated form
  matches the named-pair syntax in relation literals, so column
  declarations and column values share a surface rhythm without
  committing to schemas-as-literals.
- **Trailing `primary key (...)` clause, always parenthesised,
  always required.** Single-column PKs write `primary key (id)`, not
  `primary key id`. One grammar rule across single- and
  multi-column cases; the parens echo the multi-row relation
  literal's column-name tuple. Dovetail has no implicit rowid and
  no auto-key, so the clause is mandatory; absent `primary key` is
  an error.
- **Comma-separated, trailing comma allowed everywhere.** Matches
  relation literals.
- **Bare identifiers** for table and column names. No quoting or
  escaping mechanism; case-sensitive. Same convention as the
  existing table-reference grammar.
- **Kind names `Int64`, `String`, `Bool`.** Match `Value.Kind.t`
  exactly, so what you type as a declaration is what `describe`
  prints back. New kinds added later extend this list without
  grammar changes.

## Drop table

```
:drop table users
```

- Bare table name; the `table` keyword carries forward to future
  variants like `:drop index foo`. No idempotency clause.
- Error if the table does not exist (per Q5 of the design
  discussion: idempotency clauses are additive future ergonomics,
  not part of this design).

## Describe and list tables

```
:describe users
:list tables
```

`describe` takes a bare table name (no `:describe table users` — the
kind is contextually obvious, and the asymmetry with
create/drop is honest: those statements mutate the catalog, this one
reads it). `list tables` is the bare two-word statement; future
`list indexes`, `list views` slot in alongside.

### Round-trip property

`describe`'s output is the canonical surface form of the table's
schema, with the sigil included. The output is literally what the
user would type to recreate the table:

```
> :describe users
:create table users (
  id: Int64,
  name: String,
  email: String,
  active: Bool,
) primary key (id)
```

Canonical form rules: one column per line, two-space indent, trailing
comma on every column, `primary key (...)` on its own line after the
closing paren.

The design carries an explicit invariant:

  **For every well-formed `Create_table` statement `s`,
  `parse(format(s)) ≡ s` modulo whitespace.**

That invariant is the anchor for the printer's correctness. A
property-based test that round-trips through randomly-generated
schemas falls out naturally.

`list tables` prints one table name per line, sorted alphabetically:

```
> :list tables
orders
users
```

Not a bordered table. A bordered table would imply "this is a
relation"; the whole stance is that DDL output isn't relational.
Plain lines keep DDL output visually distinct from query output.

## Validation rules

Validation splits into two passes, with the split following the same
logic the DML design uses for mutations: structural checks happen
without the catalog; catalog-presence checks happen inside the eval
transaction.

**Structural (`Ddl.validate`, before eval):**

- Empty column list (`create table users () primary key (id)`) →
  error.
- Duplicate column name in the column list → error, naming the
  duplicate.
- Empty PK column list → error. (The grammar makes this
  unreachable, but the validator checks it defensively.)
- PK references a column not in the column list → error, naming
  the missing column.
- Duplicate column name in the PK list (`primary key (id, id)`) →
  error.
- Unknown kind name in a column declaration → error.

**Catalog-aware (`Ddl.execute`, inside the eval transaction):**

- `create table` whose name is already in the catalog → error.
- `drop table` whose name is not in the catalog → error.

The structural pass is pure: it operates on `Ddl.statement` and
returns `unit, string result`. The catalog-aware checks happen inside
the write transaction that performs the change, so the check and the
mutation can't race even across processes — LMDB serialises writers,
and a single transaction is the unit of consistency.

Error message format follows the project convention from
`CLAUDE.md`: every user-facing error starts with a module prefix and
names the operation, e.g.

```
DDL: create table "users": column "email" appears twice
DDL: drop table "orders": no such table
DDL: create table "widgets": primary key column "id" not in column list
```

## IR shape

DDL lives in its own module rather than as constructors inside
`Logical.plan`. The implementation mirrors the user-facing universe
split: relational work goes through `Logical` / `Translate` /
`Physical`; catalog work goes through `Ddl`.

```ocaml
(* lib/ddl.mli *)

type field = { name : string; kind : Value.Kind.t }
(* No qualifier: surface DDL has no notion of qualified columns. *)

type statement =
  | Create_table of {
      table_name  : string;
      fields      : field list;
      primary_key : string list;
    }
  | Drop_table of { table_name : string }
  | Describe   of { table_name : string }
  | List_tables

val validate : statement -> (unit, string) result
(* Structural checks. No catalog access. *)

val classify : statement -> [ `Read | `Write ]
(* Create/Drop are Write; Describe/List_tables are Read. *)

val execute :
  Storage.environment ->
  [ `Read | `Write ] Storage.transaction ->
  statement ->
  result

and result =
  | Created   of string         (* table name *)
  | Dropped   of string
  | Described of Schema.t
  | Listed    of string list    (* sorted *)
```

`Ddl.field` is deliberately separate from `Schema.field`. The latter
carries a `qualifier` that gets set when a `Scan` reads a table;
surface DDL has no notion of qualified columns. Reusing
`Schema.field` would mean carrying an always-`None` qualifier through
the parser and AST — a small but real form of the type lying about
the data.

The top-level program type and eval result grow to discriminate the
two universes:

```ocaml
type program =
  | Pipeline of Logical.plan
  | Ddl      of Ddl.statement

type eval_result =
  | Query    of [ `Bag ] Relation.t
  | Mutation of { affected_rows : int }
  | Ddl      of Ddl.result
```

The REPL's top-level dispatch gains one arm:

```ocaml
match program with
| Pipeline plan ->
    let transaction_kind = Logical.classify plan in
    with_transaction transaction_kind (fun transaction ->
      Eval.run plan transaction)
| Ddl statement ->
    let () = Ddl.validate statement |> raise_if_error in
    let transaction_kind = Ddl.classify statement in
    with_transaction transaction_kind (fun transaction ->
      Ddl.execute environment transaction statement)
```

Renderers per `Ddl.result` constructor:

- `Created name` → `created table "<name>"`.
- `Dropped name` → `dropped table "<name>"`.
- `Described schema` → the canonical `:create table` form.
- `Listed names` → one name per line.

Pluralisation: each DDL statement operates on one object, so the
DML-style `1 row` / `N rows` pluralisation doesn't arise here.

## Transactions

The DML design's transaction model carries over without modification,
extended by one classifier arm.

- **One operation per top-level REPL input.** An input is either a
  pipeline (Query or Mutation) or a DDL statement; they don't mix.
  Multi-statement input remains out of scope, matching DML.
- **Per-statement read/write classification.** `Ddl.classify`
  returns `` `Write `` for `Create_table` and `Drop_table`, `` `Read
  `` for `Describe` and `List_tables`. The REPL picks
  `with_read_transaction` or `with_write_transaction` accordingly.
- **Atomicity via the LMDB transaction.** `create table` is a
  catalog `put` plus a `Storage.create_map` inside one write
  transaction; either both happen or neither does. `drop table` is a
  catalog `delete` plus a `Storage.drop_map`, atomic by the same
  mechanism.
- **DDL inside a pipeline is unrepresentable in the grammar.** The
  sigil-prefixed form only appears at top of input; nesting is a
  parse error, not a validation error. No mid-pipeline DDL sink
  arm to design or maintain.
- **Error path** reuses the existing `Failure`-and-abort machinery.
  Validation raises before the transaction opens; catalog-presence
  errors raise inside the transaction, which aborts on the raise.

## Storage and catalog prerequisites

The DDL design assumes three small additions to the storage and
catalog layers. They're implementation work that falls out of the
design, not separate design decisions, but they're listed here so
they're visible in one place.

- `Storage.drop_map : environment -> [`Read | `Write] transaction
  -> name:string -> unit` — destroy a named subDB and its contents.
  Wraps LMDB's `mdb_drop` with the delete flag.
- `Catalog.delete : environment -> [`Read | `Write] transaction ->
  table_name:string -> unit` — remove a catalog entry.
- `Catalog.list_table_names : environment -> [> `Read] transaction
  -> string list` — enumerate the catalog's keys, sorted.

The subDB naming convention from the existing fixture
(`"table:" ^ table_name`) is kept and formalised in a single helper
inside `Ddl.execute`, so the `table:` namespace is reserved for
table-data subDBs and remains free for future use (e.g.
`index:<name>` once indexes exist).

## Retiring the fixture

A consequence rather than a decision: once `create table` and `drop
table` exist, the hard-coded `users` and `orders` schemas in
`lib/fixture.ml` aren't needed for the language's day-to-day use. The
fixture was a stopgap that let queries run before DDL existed. *When*
the fixture retires (and what, if anything, replaces it for tests
and demos) is a slice-plan question, not a design-doc question.

## What this design accommodates without rework

These are the items the design is consciously prepared for, even
though they belong to later slices. None of them require revisiting
the decisions here.

- **`alter table`** in any of its forms (add column, drop column,
  rename column, change kind, change PK). A new constructor in
  `Ddl.statement`; new arms in `validate` and `execute`. The
  surface and the IR layout are already shaped to absorb it.
- **`if not exists` / `if exists` idempotency clauses.** Pure
  grammar additions on `Create_table` and `Drop_table`; one
  conditional in `execute` per clause.
- **`rename table`, `truncate table`.** New `Ddl.statement`
  constructors. Both are trivially expressible in the existing
  IR shape.
- **`create index` / `drop index`** once secondary indexes are a
  user-visible concept. The subDB-namespace convention reserved
  `table:<name>` already; `index:<name>` slots in alongside.
- **System-tables-style queryable introspection.** A future
  decision to surface the catalog as built-in relations (`_tables`,
  `_columns`) doesn't conflict with the DDL statement universe —
  the two can coexist, with `describe` and `list tables` remaining
  the ergonomic interactive forms.
- **Multi-statement input and explicit transactions.** Orthogonal to
  everything above; shared with the DML design's Beyond list.
- **Additional kinds.** Adding `Float64`, `Date`, etc. extends the
  kind grammar by one identifier match per kind; nothing in the
  DDL surface or IR depends on the current kind set.
