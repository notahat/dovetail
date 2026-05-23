(** Byte encoding for keys and row values.

    Key encoding is hand-rolled and byte-comparable: comparing two encoded keys
    with [String.compare] (or [memcmp]) yields the same ordering as comparing
    the original values. Only [int64] keys are currently supported; further key
    types will arrive when needed.

    Row value encoding is currently [Marshal]-based. The Marshal coupling to
    OCaml's runtime representation is accepted for now and will be replaced with
    hand-rolled binary alongside composite-key encoding. *)

module Scalar = Dovetail_core.Scalar

val encode_int64_key : int64 -> string
(** Encode an [int64] as 8 bytes, big-endian with the sign bit flipped, so that
    lexicographic comparison of two encoded keys agrees with [Int64.compare] on
    the originals. *)

val decode_int64_key : string -> int64
(** Inverse of {!encode_int64_key}. Raises [Invalid_argument] if the input is
    not exactly 8 bytes. *)

val encode_row_value : Scalar.data list -> string
(** Encode a list of values as bytes via [Marshal]. Used to serialise the non-PK
    columns of a row. *)

val decode_row_value : string -> Scalar.data list
(** Inverse of {!encode_row_value}. Trusts that the input was produced by
    {!encode_row_value} for a [Scalar.data list]; supplying mismatched bytes is
    undefined behaviour, per [Marshal]'s contract. *)
