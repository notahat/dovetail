(** Table schemas.

    A schema is an ordered list of named, typed fields plus the names of the
    columns that form the primary key. Schemas describe shape only -- tuples
    (the actual row values) are produced and consumed by other modules, so this
    module deliberately depends only on [Value.Kind] and not on [Value.t]. *)

type field = { name : string; kind : Value.Kind.t }
(** A single column declaration. *)

type t = { fields : field list; primary_key : string list }
(** Table schema. [primary_key] names columns drawn from [fields], in key order.
    Slice 1 only exercises single-column primary keys, but the type supports
    multi-column keys from day one so later slices need not migrate it. *)
