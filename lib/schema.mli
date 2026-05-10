(** Table schemas.

    A schema is an ordered list of named, typed fields plus the names of the
    columns that form the primary key. Schemas describe shape; tuples
    ({!type-tuple}) carry the actual row values, in field order.

    Slice 4 step 3 adds a per-field [qualifier] so multi-relation results
    (cross-product, future joins) can disambiguate same-named columns coming
    from different inputs, and a {!type-column_reference} type that captures the
    parser-level form of a column reference -- bare or dotted. *)

type field = { name : string; kind : Value.Kind.t; qualifier : string option }
(** A single column declaration. [qualifier] is set to [Some table_name] for
    fields produced by a {!Logical.Scan} of [table_name]; intermediate relations
    preserve the qualifier their fields had on the way in. *)

type t = { fields : field list; primary_key : string list }
(** Table schema. [primary_key] names columns drawn from [fields], in key order.
    Multi-column keys are supported even though slice 1 only exercises
    single-column keys. *)

type tuple = Value.t array
(** A row's values, in field order. An array (rather than a list) so
    column-position lookups are O(1). *)

type column_reference = { qualifier : string option; name : string }
(** A reference to a column by name, with an optional qualifier. The parser
    produces [{ qualifier = None; name }] for the bare form [name] and
    [{ qualifier = Some q; name }] for the dotted form [q.name]. *)

val find_field : t -> column_reference -> (int * field, string) result
(** [find_field schema reference] resolves [reference] against [schema] and
    returns the matching field's zero-based position together with the field
    record.

    Resolution rules:

    - Qualified reference ([Some qualifier, name]): match the unique field whose
      [qualifier] and [name] both match. An [Error] is returned if no such field
      exists.
    - Unqualified reference ([None, name]): match the unique field whose [name]
      matches. An [Error] is returned if no field has the name, and also if more
      than one field does (the message names the conflicting qualifiers, e.g.
      [ambiguous column reference "id": matches "users.id" and "orders.id"]).

    The error string is the body of the message; callers prepend their own
    [Predicate.resolve:] or [Projection.resolve:] prefix. *)

val format_column_reference : column_reference -> string
(** Render a [column_reference] in its source form: dotted [qualifier.name] when
    qualified, bare [name] when unqualified. *)

val assemble_tuple :
  t ->
  primary_key_values:Value.t list ->
  non_primary_key_values:Value.t list ->
  tuple
(** [assemble_tuple schema ~primary_key_values ~non_primary_key_values] builds a
    tuple in field order by interleaving the two value lists according to
    [schema.primary_key]. [primary_key_values] must be in primary-key order (the
    order they appear in [schema.primary_key]); [non_primary_key_values] must be
    in field order, omitting the PK columns.

    Used to reconstruct a tuple after reading a row from storage, where the PK
    columns come from the decoded key and the remaining columns from the decoded
    value. Raises [Invalid_argument] if either list has the wrong length. *)
