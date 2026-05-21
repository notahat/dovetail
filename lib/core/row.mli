(** The row rung of the framework: a kind describes the shape, data carries the
    values.

    [Row.kind] is the ordered list of fields a row conforms to -- a name, a
    {!Value.kind}, and an optional qualifier per position. The qualifier is
    [None] for rows produced by a plain table scan and [Some table_name] when a
    cross product or join exposes same-named columns from different inputs.

    [Row.data] is the values themselves, in field order. An array (rather than a
    list) so column-position lookups are O(1) on the hot path. *)

type field = { name : string; kind : Value.kind; qualifier : string option }
(** A single column declaration: the column's name, its value kind, and an
    optional qualifier that disambiguates same-named columns across joined
    inputs. *)

type kind = field list
(** The shape of a row: an ordered list of fields. *)

type data = Value.data array
(** A row's values, in field order. *)

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

val find_field : kind -> column_reference -> (int * field, string) result
(** [find_field row_kind reference] resolves [reference] against [row_kind] and
    returns the matching field's zero-based position together with the field
    record.

    Qualified references must match a field whose qualifier and name both match.
    Unqualified references must match a unique field by name; if more than one
    field has the same name, the error names the conflicting qualifiers. *)
