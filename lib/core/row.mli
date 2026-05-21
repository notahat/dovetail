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
