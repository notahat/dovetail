(** A kind-tagged stream of rows produced by query evaluation.

    A relation is the runtime representation of intermediate and final query
    results: a {!kind} describing the row shape and refinements, paired with a
    lazy [Seq.t] of {!Row.value} in that shape. The phantom [`Set] / [`Bag] tag
    declares whether the relation has duplicate-elimination semantics, allowing
    the type system to reject combinations that would silently change those
    semantics. The full table scan -- currently the only producer -- emits
    [[`Bag] t].

    Relations are tied to the transaction that produced their [value] sequence.
    The sequence must be consumed before the transaction's callback returns;
    using a relation outside its originating transaction's scope is undefined
    behaviour and not statically prevented. *)

(** A constraint that a relation's contents must satisfy, beyond its row shape.
    The list of refinements on a {!kind} grows as new kinds of constraint arrive
    (uniqueness, check expressions, cardinality bounds, …); for now only the
    primary key is represented. *)
type refinement = Primary_key of string list

type kind = { row_kind : Row.kind; refinements : refinement list }
(** The shape and refinements of a relation: a {!Row.kind} declaring the row
    layout, plus zero or more {!refinement}s constraining the contents. *)

type 'tag t = {
  kind : kind;
  value : Row.value Seq.t;
}
  constraint 'tag = [< `Set | `Bag ]
(** A relation tagged with its multiplicity semantics: a {!kind} describing the
    row shape and refinements, plus a lazy sequence of rows in that shape. *)

val primary_key_names : kind -> string list
(** [primary_key_names kind] returns the primary-key column names from [kind]'s
    refinements, in declared order, or the empty list when no [Primary_key]
    refinement is present. *)

val split_row : kind -> Row.value -> Scalar.value list * Scalar.value list
(** [split_row kind row] returns [(primary_key_values, non_primary_key_values)],
    where [primary_key_values] are the values at the primary-key columns (in
    primary-key order) and [non_primary_key_values] are the values at the
    remaining columns (in field order). Raises [Invalid_argument] if [row] does
    not have the right length for [kind]. *)

val assemble_row :
  kind ->
  primary_key_values:Scalar.value list ->
  non_primary_key_values:Scalar.value list ->
  Row.value
(** [assemble_row kind ~primary_key_values ~non_primary_key_values] is the
    inverse of {!split_row}: it interleaves the two value lists according to the
    kind's primary key to produce a row in field order. Raises
    [Invalid_argument] if either list has the wrong length. *)

val format_kind : Format.formatter -> kind -> unit
(** [format_kind formatter kind] writes [kind] to [formatter] in the surface
    syntax for a relation type: the row-type form (via {!Row.format_kind}) with
    refinement clauses interleaved as additional comma-separated entries.
    [Primary_key columns] renders as [primary key (col1, col2, ...)]. When
    [refinements] is empty the output is identical to the row-type form. *)

val format : Format.formatter -> _ t -> unit
(** [format formatter relation] writes [relation] to [formatter] in the surface
    syntax for a relation value: the [relation (T) { rows }] literal form, where
    [T] is the relation type rendered via {!format_kind} and the rows are
    rendered via {!Row.format}. An empty relation renders inline as
    [relation (T) {}]; a relation with rows breaks across lines, with each row
    indented by two spaces on its own line, comma-separated, and a closing brace
    on the final line. Materialises the [value] sequence eagerly. Field
    qualifiers in the row kind are preserved, matching {!format_kind} and
    {!Row.format}.

    No trailing newline is emitted after the closing brace, matching
    {!Scalar.format}, {!Row.format}, and {!format_kind}. *)
