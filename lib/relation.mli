(** A schema-tagged stream of tuples produced by query evaluation.

    A relation is the runtime representation of intermediate and final query
    results: a schema describing the row shape, paired with a lazy [Seq.t] of
    tuples in that shape. The phantom [`Set] / [`Bag] tag declares whether the
    relation has duplicate-elimination semantics, allowing the type system to
    reject combinations that would silently change those semantics. Slice 1's
    only producer (full table scan) emits [[`Bag] t].

    Relations are tied to the transaction that produced their [tuples] sequence.
    The sequence must be consumed before the transaction's callback returns;
    using a relation outside its originating transaction's scope is undefined
    behaviour and not statically prevented in slice 1. *)

type 'tag t = {
  schema : Schema.t;
  tuples : Schema.tuple Seq.t;
}
  constraint 'tag = [< `Set | `Bag ]
(** A relation tagged with its multiplicity semantics. *)

val print : ?formatter:Format.formatter -> _ t -> unit
(** [print ?formatter relation] renders [relation] as a pipe-delimited ASCII
    table to [formatter] (defaulting to [Format.std_formatter]).

    Column widths are sized to the wider of the header and the rendered values;
    [Int64] columns are right-aligned and the others left-aligned. Materialises
    the [tuples] sequence eagerly to compute widths, so all rows are pulled
    before any output is produced. *)
