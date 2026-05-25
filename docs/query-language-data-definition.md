# Query language: data definition reference

Part of the [query-language guide](query-language.md). Data-definition
statements inspect the catalog rather than read or write rows. They
are distinguished from pipelines by a leading `:` sigil: anything
starting with `:` (after optional whitespace) is parsed as a
data-definition statement; anything else is parsed as a pipeline.

The sigil is only meaningful at the very start of input. Inside a
pipeline, expression, or column list, `:` remains a parse error, and
the keywords `list`, `tables` are ordinary identifiers -- they only
acquire special meaning after the sigil has been consumed.

Today's only DDL statement is `:list tables`. Adding and removing
tables now live in the pipeline grammar:

- `<type-expr> | create table <name>` and
  `<relation-value> | create table <name>` -- see the
  [`create table`](query-language-pipeline-operators.md#create-table)
  section of the pipeline-operators reference.
- `drop table <name>` -- a leaf pipe source; see the
  [`drop table`](query-language-pipeline-operators.md#drop-table)
  section.

To inspect a table's schema, pipe it into the `type` operator:
`<name> | type`. The operator yields the relation's type without
opening any cursors. This replaces the earlier `:describe` form.

## `:list tables`

**Syntax:** `:list tables`

Prints the name of every table in the catalog, one per line, in
byte-sorted order. An empty catalog produces no output between
prompts. The statement runs inside a read transaction and never
modifies state.

```
> :list tables
orders
users
```
