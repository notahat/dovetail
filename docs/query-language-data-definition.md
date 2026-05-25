# Query language: data definition reference

Part of the [query-language guide](query-language.md). Data definition
no longer has a sigil-prefixed form: every statement has been retired
in favour of pipe-form operators. This page remains as a redirect for
historical links; it will be removed when the next slice collapses the
empty DDL universe.

- `<type-expr> | create table <name>` and
  `<relation-value> | create table <name>` -- see the
  [`create table`](query-language-pipeline-operators.md#create-table)
  section of the pipeline-operators reference.
- `drop table <name>` -- a leaf pipe source; see the
  [`drop table`](query-language-pipeline-operators.md#drop-table)
  section.
- `catalog | tables` -- list the names of every table in the catalog
  as a one-column `(name: string)` relation. Replaces the earlier
  `:list tables` form.
- `<name> | type` -- inspect a table's schema without opening any
  cursors. Replaces the earlier `:describe` form.
