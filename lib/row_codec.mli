(** Schema-driven row decoding.

    Bridges {!Schema} (table shape, tuple assembly) and {!Encoding} (byte-level
    key and value codecs). Storage hands rows back as raw
    [(key_bytes, value_bytes)] pairs; decoding them into a {!Schema.tuple}
    requires both the schema (to know which columns are primary-key columns and
    what kinds they are) and the encoding (to interpret the bytes). This module
    owns that composition so {!Eval} -- and any future inserter or index reader
    -- can stay focused on its own concerns.

    Slice 1 only handles a single int64 primary-key column. Composite keys and
    other key kinds arrive in later slices alongside the hand-rolled binary
    encoding. *)

val decode_row : Schema.t -> string * string -> Schema.tuple
(** [decode_row schema (key_bytes, value_bytes)] reconstructs a tuple in field
    order, drawing primary-key columns from [key_bytes] and the remaining
    columns from [value_bytes].

    Raises [Failure] if [schema] declares a composite or non-[int64] primary key
    (slice 1 limitation). *)

val encode_row : Schema.t -> Schema.tuple -> string * string
(** [encode_row schema tuple] is the inverse of {!decode_row}: it splits [tuple]
    into its primary-key and non-primary-key values according to [schema] and
    encodes each side with {!Encoding}. The returned pair is suitable for
    passing as [~key] and [~value] to {!Storage.put}.

    Raises [Failure] if [schema] declares a composite or non-[int64] primary
    key, mirroring {!decode_row}'s slice 1 limitation. Raises [Invalid_argument]
    if [tuple] is not the right length for [schema]. *)
