# Literals as a ladder

A design note, not a plan. It captures a framing for thinking about
schemas, relations, catalogs, and DDL as facets of one idea —
round-trippable literals at every level of granularity — rather than as
the unrelated special cases SQL presents them as.

## The observation that started it

Dovetail can round-trip schemas: `create table` text parses to a schema,
`describe` prints a schema back to `create table` text. Dovetail can
parse relation literals but cannot print them, so relations do not
round-trip. The obvious fix is to add a printer for relation literals.
The more interesting question is what the symmetry between schema and
relation should look like once both round-trip.

`create table` is not really a value↔text round trip. It is a
value↔*program-that-builds-the-value* round trip: the text is a
statement which, when executed, produces the schema. Relation literals
are the other kind of symmetry: text that *denotes* a value directly.
Dovetail currently has one of each, which is why the situation feels
lopsided.

## The ladder

Once you ask "what would a schema *literal* look like?", the shape of
the answer is a small stack of paired types and values:

| Type | Value |
| --- | --- |
| schema (row shape: names, types, nullability) | row / tuple |
| table type (schema + value refinements: PK, unique, check) | relation |
| database type (table types + catalog invariants: foreign keys) | catalog |
| + physical metadata (indexes, storage hints) | on-disk database |

Each rung composes the rung below. A table is a schema plus refinements
plus rows. A database is a set of named tables plus invariants between
them. The on-disk form is a database plus the operational metadata
needed to store and access it.

The round-trippable-literal question lives at every rung, not just at
schema. A table literal is a schema plus refinements plus rows. A
database literal is a set of named table literals plus invariants. Each
is a printer/parser pair against the value at that rung.

## What this locates

- **RA stays purely logical.** Relational algebra operates one rung
  down: relations to relations. Schemas and refinements flow through
  it. Foreign keys are catalog-level invariants, checked at mutation
  boundaries, not inside RA expressions. Indexes are invisible to RA
  entirely — the planner consults them, the algebra does not.
- **DDL is catalog mutation.** `create table`, `drop table`, `alter
  table` are an imperative-shell language for mutating the catalog
  value, the same way `insert`/`update`/`delete` are an imperative
  shell for mutating relations. If the catalog has a literal form, DDL
  becomes ordinary binding/rebinding over that literal rather than a
  separate grammar.
- **Physical metadata is below the logical model.** Indexes and storage
  hints do not belong in any logical literal. They sit alongside the
  database value, not inside it.

## SQL as a list of special cases

Once the ladder is in view, the SQL surface reads as one special-case
per rung instead of one uniform mechanism:

- `VALUES (1, 2, 3)` is a row literal — with no real way to name and
  reuse one.
- `CREATE TABLE` is catalog mutation as bespoke statement syntax.
- `INSERT` is relation mutation as bespoke statement syntax.
- `pg_dump` is out-of-band tooling that emits a *script of statements*
  rather than a database value. Loading it is "execute this program",
  not "parse this literal".
- Migrations are a whole separate ecosystem because the language has
  no notion of database-literal-diff.
- `information_schema` and `\d` are yet another surface for reading
  back what the literals would have said.

Each of these is a different grammar, a different tool, a different
mental model. All of them are reinventing "print and parse at rung N"
because the language never committed to literals as a uniform
mechanism.

## What the endpoint would look like

If Dovetail went all the way and had literals at every rung:

- "Dump database" and "load database" are the same operation as
  printing and parsing a database literal.
- Migrations are a diff between two database literals.
- DDL is binding (and rebinding) over catalog literals; it is not a
  separate language.
- Introspection (`describe`, listing tables) is pretty-printing a
  sublevel of the catalog literal.

This is more than Dovetail needs to build now. It is a coherent
endpoint that the schema-literal idea points toward, and the value of
writing it down is so the near-term moves (printing relations,
sketching schema literals) stay aimed at it rather than drifting into
their own special cases.

## A speculative syntax sketch

Probably not the syntax Dovetail will end up with. Captured because the
shape it lands on — one record/refinement form recurring at every rung
— is the part worth keeping even if the surface details change. The
sketch assumes a language closer to mathematical RA than to Dovetail's
current pipe-style surface.

The unifying move is to make `{ ... }` the workhorse at every rung,
distinguishing values from types only by what's inside.

### Row rung

A row is a named tuple — a finite map from labels to values. Its type
is the same shape with types instead of values:

```
row literal:  { id = 1, name = "alice" }
row type:     { id : int, name : text }
```

`=` binds a label to a value, `:` binds a label to a type. Same brace
syntax, different right-hand side. The row type is exactly what we've
been calling a schema.

### Relation rung

A relation is a set of rows. Set-builder notation does the work:

```
{
  { id = 1, name = "alice" },
  { id = 2, name = "bob"   },
}
```

That's it for the unrefined relation literal — a set whose elements are
row literals. An empty relation needs its schema annotated, since `{}`
on its own is ambiguous:

```
{} : { id : int, name : text }
```

A *table type* is the row type plus value refinements. Mathematical
refinement-type form falls out naturally:

```
{ row : { id : int, name : text } | unique row.id }
```

— "the set of relations of this row type where `id` is unique." Check
constraints are predicates in the same position. A pragmatic sugar
form, if the refinement-type version is too dense for the common case:

```
{ id : int, name : text  key id }
```

with `key`, `check`, `unique` as keyword-introduced refinements that
desugar to the predicate form.

### Refinements in more detail

The single `unique row.id` example above hides the structure of what's
available. The useful split is between **per-row** refinements
(predicates on a single row) and **set-level** refinements (predicates
on the whole relation).

**Per-row refinements** have a free `row` variable. Each one constrains
every row independently:

```
-- Check constraints
{ row : { id : int, age : int } | row.age >= 0 }

-- Domain restrictions
{ row : { ..., status : text }
  | row.status ∈ { "open", "closed", "void" } }

-- Format constraints
{ row : { ..., email : text }
  | row.email matches /^[^@]+@[^@]+$/ }

-- Generated columns as equalities
{ row : { qty : int, price : int, total : int }
  | row.total = row.qty * row.price }
```

That last one is worth a beat: a generated column *is* a per-row
equality refinement. Whether you store it or recompute it is an
implementation choice; the type-level statement is the same.

**Set-level refinements** quantify over the rows of the relation:

```
-- Uniqueness (key)
{ r | ∀ x, y ∈ r. x.id = y.id ⟹ x = y }

-- Composite key
{ r | ∀ x, y ∈ r.
      (x.user_id, x.role_id) = (y.user_id, y.role_id) ⟹ x = y }

-- Functional dependency: zip determines city
{ r | ∀ x, y ∈ r. x.zip = y.zip ⟹ x.city = y.city }

-- Cardinality bounds
{ r | |r| ≤ 1 }     -- singleton table
{ r | |r| ≥ 1 }     -- non-empty

-- Density / ordering invariants
{ r | { x.seq | x ∈ r } = { 1, ..., |r| } }
```

Keys are a special case of functional dependency (an FD with the whole
row on the right). Mathematical RA already knows this — FDs are the
more fundamental concept, and the literature often presents keys as
sugar over FDs.

**Sugar forms.** Almost nobody wants to write the quantified versions
in everyday code. Keyword sugar that desugars to refinements:

```
{ id : int, name : text, age : int
  key id
  check (age >= 0)
}

{ user_id : int, role_id : int
  key (user_id, role_id)
}

{ zip : text, city : text
  fd (zip → city)
}
```

`key`, `check`, `fd`, `unique` — each a keyword introducing a predicate
in restricted syntactic form, with a desugaring to the refinement-type
core.

**What is not a refinement, and why.** A few things look like they
might be refinements but are better placed elsewhere:

- **Nullability** is part of the column *type* (`text?` vs `text`), not
  a relation-level predicate. Putting it in the row type means it
  flows through projection automatically and you don't write the same
  null-check predicate on every relation.
- **Default values** are an insert-time concern — they fill in a value
  when one isn't provided. They don't constrain which relations are
  valid, so they're not refinements. They belong on the column as
  metadata alongside the type.
- **Foreign keys** are catalog-level invariants, not table-level
  refinements. They reference *another* relation, which a refinement
  of a single table type can't talk about. They live one rung up.

**What refinements buy you.** Two things, not one. Validation is the
obvious half: at insert / update time, check that the new relation
still satisfies the refinement, and reject the mutation if not. The
less obvious half is *planner knowledge*: a unique key tells the
planner a join is at most one-to-one, an FD lets it rewrite queries, a
cardinality bound of 1 lets it skip whole branches. Refinements are
simultaneously correctness constraints and optimisation hints, and
they're the same predicates either way — the planner just gets to
*assume* them because validation enforces them.

That dual role is part of why expressing them as plain predicates is
appealing: the planner reads them as math, not as ad-hoc metadata.

### Catalog rung

A catalog is a record of named relations. Same brace syntax, one rung
up:

```
{
  users = {
    { id = 1, name = "alice" },
    { id = 2, name = "bob"   },
  },
  orders = {
    { id = 100, user_id = 1, total = 42 },
  },
}
```

A catalog type is a record of table types, plus invariants over the
whole record. Foreign keys are the prototypical case:

```
{
  users  : { row : { id : int, name : text } | key row.id },
  orders : { row : { id : int, user_id : int, total : int }
             | key row.id },

  | ∀ o ∈ orders. ∃ u ∈ users. o.user_id = u.id
}
```

i.e. the catalog type itself is a refinement: a record-of-tables
subject to a predicate. Foreign keys are not a special form, just a
common shape of catalog invariant.

### RA operators and bindings

Operators are functions over relation values, written mathematically:

```
σ_{age > 18}(users)
π_{id, name}(users)
users ⋈_{users.id = orders.user_id} orders
users ∪ { { id = 3, name = "carol" } }
```

DDL is now `let`-binding over a mutable catalog. `create table` and
`insert` are not separate grammars:

```
let users : { id : int, name : text  key id } := {} in
  users := users ∪ { { id = 1, name = "alice" } } ;
  ...
```

`drop table` is unbinding. `alter table` is rebinding with a new type
(plus a coercion of the existing rows, which becomes an explicit RA
expression rather than implicit magic).

### The shape that recurs

At every rung the syntax is one of:

- `{ label = value, ... }` — record value
- `{ label : type, ... }`  — record type
- `{ element, element, ... }` — set value
- `{ x : T | predicate(x) }` — refinement type

Rows are record values; schemas are record types; relations are sets of
records; table types are refinements of "set of records of type T";
catalogs are record values whose fields are relations; database types
are refinements of "record-of-tables." Same four forms, composed.

### What's worth pushing back on

A few choices to surface rather than assume:

- **Named vs positional tuples.** Named throughout above. Positional is
  more compact for relation literals (no repeated labels per row) but
  loses the property that row literal and row type are the same shape.
  Worth deciding which symmetry matters more.
- **`=` for values, `:` for types.** Clean but means a row literal and
  a row type don't look alike inside `{}`. The alternative — `:` for
  both — is uniform but you have to look at what's right of the colon
  to know which kind of thing you're reading.
- **Refinement-as-primary vs keyword sugar.** Pure `{ x : T | P(x) }`
  is beautifully uniform; keyword sugar (`key`, `unique`, `check`) is
  what people will actually want to write. The honest answer is
  probably both, with the sugar desugaring to refinements.
- **Set semantics vs bag semantics.** Mathematical RA is set-based;
  real databases are bag-based. The syntax above silently assumes
  sets. If bags matter, the literal form needs a way to express
  duplicates and the operators need their bag variants.

The thing genuinely appealing in this sketch is that "schema", "table",
and "database" stop being three different kinds of declaration and
become three uses of the same record/refinement machinery at different
rungs. Whether that survives contact with bag semantics, nullability,
and the operator zoo is the real test.

## What this note is not

- Not a plan. No syntax is committed to here. The shape of a relation
  literal that carries a header, versus a separate schema literal, is
  still open; so is everything above the table rung.
- Not a claim that Dovetail will implement every rung. The ladder is a
  way to *locate* features, including the ones that will never be
  built.
- Not a critique of SQL on its own terms. SQL's surface reflects
  decades of constraints Dovetail does not have. The point is only
  that those special cases stop looking necessary once the ladder is
  in view.
