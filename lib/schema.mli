(** Table schemas.

    A schema is an ordered list of named, typed fields plus the names of the
    columns that form the primary key. Schemas describe shape; tuples
    ({!type-tuple}) carry the actual row values, in field order. *)

type field = { name : string; kind : Value.Kind.t }
(** A single column declaration. *)

type t = { fields : field list; primary_key : string list }
(** Table schema. [primary_key] names columns drawn from [fields], in key order.
    Slice 1 only exercises single-column primary keys, but the type supports
    multi-column keys from day one so later slices need not migrate it. *)

type tuple = Value.t array
(** A row's values, in field order. An array (rather than a list) so
    column-position lookups are O(1). *)
