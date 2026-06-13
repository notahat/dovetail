# Storage

How Dovetail persists tables on LMDB: the layering of
[`lib/storage/`](../../lib/storage/), the byte format for keys and
rows, how the catalog persists, and the transaction-and-cursor
lifetime story that drives the executor's shape. The load-bearing
facts: keys are encoded to be byte-comparable so a cursor walks rows
in primary-key order; row values are `Marshal`-encoded (a known
limitation); the catalog is itself just another subDB; and
transactions are scope-bound, which is *why* a relation's lazy row
sequence is only valid inside the transaction that produced it.

## The layers

`lib/storage/` is four modules, lowest to highest:

- [`Engine`](../../lib/storage/engine.mli) — the thin layer over the
  `lmdb` package. It fixes one shape for everything above it: every
  key and every value is a `string` of bytes. Environments,
  transactions, and named subDBs (`map`); `get` / `put` / `delete`
  and the cursor primitive. No kinds, rows, or catalog awareness —
  encoding lives above.
- [`Encoding`](../../lib/storage/encoding.mli) — the byte codecs for
  keys and row values.
- [`Row_codec`](../../lib/storage/row_codec.mli) — the kind-driven
  bridge: it knows how to split a row into its key and value halves
  and reassemble it, using `Relation.kind` to decide which columns
  are the primary key.
- [`Catalog`](../../lib/storage/catalog.mli) — the persistent map
  from table name to `Relation.kind`, layered on a single subDB.

## Key encoding is byte-comparable

LMDB orders keys by `memcmp` (lexicographic byte comparison), and
Dovetail leans on that ordering: a `FullScan` opens a cursor and
walks rows in key order, which must be *primary-key* order to be
meaningful. So the key encoding has one hard requirement —
lexicographic comparison of two encoded keys must agree with numeric
comparison of the original values.

A naïve big-endian `int64` fails this for negative numbers:
two's-complement negatives have their top bit set, so they'd sort
*after* the positives under `memcmp`. The fix in
[`encoding.ml`](../../lib/storage/encoding.ml) is to flip the sign
bit (`logxor` with `Int64.min_int`) before writing the 8 big-endian
bytes. That shifts the signed range `[min_int, max_int]` onto the
unsigned range `[0, 2^64 - 1]`, so byte order matches `Int64.compare`.
The mapping is its own inverse, so decoding flips the same bit back.

Only single-column `int64` primary keys are supported today.
Composite keys and other key kinds arrive alongside the hand-rolled
value encoding below.

## Row encoding: key/value split, Marshal values

A table's rows live in their own subDB, named by the `table:`
convention — `table:users` holds the rows of `users`
(`Catalog.table_subdb_name` is the single source of truth for that
string). Each row is split across the LMDB key and value:

- The **key** is the encoded primary-key column (the byte-comparable
  `int64` above). The primary key lives *only* in the key — it is not
  repeated in the value.
- The **value** is the remaining (non-primary-key) columns, encoded
  together.

`Row_codec` drives the split using the table's `Relation.kind`:
`encode_row` projects out the PK columns, encodes them as the key and
the rest as the value; `decode_row` reverses it, drawing PK columns
from the key bytes and the rest from the value bytes, then
reassembling them into a `Row.value` in field order.

The value half is encoded with OCaml's `Marshal`. **This is a known,
deliberate limitation, not a finished design.** Marshal couples the
on-disk bytes to OCaml's runtime representation, with two
consequences worth being explicit about:

- The bytes are tied to the OCaml version that wrote them; an
  environment written by one compiler is not guaranteed to read back
  under another.
- There is no version tag and no migration path. The working
  assumption is that the Marshal format gets replaced wholesale by a
  hand-rolled binary encoding (landing together with composite-key
  support), at which point existing environments are discarded rather
  than migrated.

## The catalog is just another subDB

The catalog — the map from table name to `Relation.kind` — has no
special storage machinery. It is a single subDB literally named
`catalog`, keyed by the table name as UTF-8 bytes, with the
`Relation.kind` as a `Marshal`-encoded value. The same Marshal
caveats apply, and more sharply: any change to the shape of
`Relation.kind` (or anything it transitively reaches) invalidates
every catalog already on disk.

The subDB is created lazily on the first `put`, so reads against a
brand-new environment return `None` (or an empty list/kind) rather
than raising. `Catalog.snapshot_kind` walks the whole subDB and
returns a `Catalog.kind` pairing each table name with its stored
relation kind — this is the snapshot `Typecheck` validates against,
taken inside the caller's read transaction so the kinds can't shift
before evaluation.

Note the division of labour around missing tables: the storage-level
`delete` is a silent no-op on an absent key, and the user-facing "no
such table" error lives one layer up in `Eval_drop_table`, so the
check and the drop can share a transaction scope.

## Transactions, cursors, and relation lifetime

This is the constraint that shapes the whole executor. Transactions
are **scope-bound**: `with_read_transaction` and
`with_write_transaction` run a callback and tear the transaction down
when it returns (a read aborts; a write commits on normal return,
aborts on a raise — so multi-row writes are all-or-nothing). A cursor
opened against a transaction is valid *only* until that callback
returns.

The cursor primitive, `with_iter_seq`, is the same shape one level
down: it opens a cursor, hands its callback a one-shot `Seq.t` that
pulls key-value pairs straight from the live cursor in key order, and
tears the cursor down when the callback returns. The sequence is
lazy and single-pass — valid only inside the callback, exhausted once
walked, and safe to abandon partway.

Because a relation's `value` sequence pulls from a live cursor, the
relation is only usable while its transaction and cursor are alive.
It cannot be returned and iterated later. That is exactly why
evaluation is in continuation-passing style — the consumer must run
*inside* the cursor scope rather than receiving a relation that would
outlive it. The full argument, and the alternatives that were ruled
out, are in [executor.md](executor.md).
