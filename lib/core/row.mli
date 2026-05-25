(** The row rung of the framework: a kind describes the shape, a value carries
    the cells.

    [Row.kind] is the ordered list of fields a row conforms to -- a name, a
    {!Scalar.kind}, and an optional qualifier per position. The qualifier is
    [None] for rows produced by a plain table scan and [Some table_name] when a
    cross product or join exposes same-named columns from different inputs.

    [Row.value] is the cells themselves, in field order. An array (rather than a
    list) so column-position lookups are O(1) on the hot path. *)

type field = { name : string; kind : Scalar.kind; qualifier : string option }
(** A single column declaration: the column's name, its value kind, and an
    optional qualifier that disambiguates same-named columns across joined
    inputs. *)

type kind = field list
(** The shape of a row: an ordered list of fields. *)

type value = Scalar.value array
(** A row's cells, in field order. *)

type t = { kind : kind; value : value }
(** A row paired with the {!kind} that describes its shape. The companion to
    {!Relation.t} at the row rung — values and shapes travel together so a row
    can be rendered or type-checked without separate plumbing. *)

type column_reference = { qualifier : string option; name : string }
(** A reference to a column by name, with an optional qualifier. The parser
    produces [{ qualifier = None; name }] for the bare form [name] and
    [{ qualifier = Some q; name }] for the dotted form [q.name]. *)

val format_column_reference : column_reference -> string
(** Render a [column_reference] in its source form: dotted [qualifier.name] when
    qualified, bare [name] when unqualified. *)

val format_field_name : field -> string
(** Render a [field]'s display name in source form: dotted [qualifier.name] when
    the field carries a qualifier, bare [name] otherwise. *)

val format_kind : Format.formatter -> kind -> unit
(** [format_kind formatter kind] writes [kind] to [formatter] in the surface
    syntax for a row type: a parenthesised, comma-separated list of [name: type]
    bindings, or [()] when [kind] is empty. Field names render via
    {!format_field_name}, so qualifiers appear as [qualifier.name] when present
    and bare otherwise. Field kinds render via {!Scalar.format_kind} (lowercase
    keywords). *)

val format : Format.formatter -> t -> unit
(** [format formatter row] writes [row] to [formatter] in the surface syntax for
    a row value: a parenthesised, comma-separated list of [name = value]
    bindings, or [()] when the row is empty. Field names render via
    {!format_field_name}, so qualifiers appear as [qualifier.name] when present
    and bare otherwise. Cell values render via {!Scalar.format}. *)

val unqualify_kind : kind -> (kind, string) result
(** [unqualify_kind row_kind] returns [row_kind] with every field's qualifier
    stripped to [None]. Returns [Error message] if two fields would collide on
    their bare name after stripping; the message names the colliding bare name
    and the two original qualified spellings, so the caller can wrap it with its
    own operator prefix. *)

val find_field : kind -> column_reference -> (int * field, string) result
(** [find_field row_kind reference] resolves [reference] against [row_kind] and
    returns the matching field's zero-based position together with the field
    record.

    Qualified references must match a field whose qualifier and name both match.
    Unqualified references must match a unique field by name; if more than one
    field has the same name, the error names the conflicting qualifiers. *)
