(** Kind-driven row decoding.

    Bridges {!Relation} (relation kind, row assembly) and {!Encoding}
    (byte-level key and value codecs). Storage hands rows back as raw
    [(key_bytes, value_bytes)] pairs; decoding them into a {!Row.value} requires
    both the kind (to know which columns are primary-key columns and what kinds
    they are) and the encoding (to interpret the bytes). This module owns that
    composition so {!Eval} -- and any future inserter or index reader -- can
    stay focused on its own concerns.

    Currently only handles a single int64 primary-key column. Composite keys and
    other key kinds will arrive alongside the hand-rolled binary encoding. *)

module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

val decode_row : Relation.kind -> string * string -> Row.value
(** [decode_row kind (key_bytes, value_bytes)] reconstructs a row in field
    order, drawing primary-key columns from [key_bytes] and the remaining
    columns from [value_bytes].

    Raises [Failure] if [kind] declares a composite or non-[int64] primary key
    (current limitation). *)

val encode_row : Relation.kind -> Row.value -> string * string
(** [encode_row kind row] is the inverse of {!decode_row}: it splits [row] into
    its primary-key and non-primary-key values according to [kind] and encodes
    each side with {!Encoding}. The returned pair is suitable for passing as
    [~key] and [~value] to {!Engine.put}.

    Raises [Failure] if [kind] declares a composite or non-[int64] primary key,
    mirroring {!decode_row}'s limitation. Raises [Invalid_argument] if [row] is
    not the right length for [kind]. *)
