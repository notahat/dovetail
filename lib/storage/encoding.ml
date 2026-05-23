module Scalar = Dovetail_core.Scalar

(* Map an int64 between signed-comparison order and unsigned-comparison
   order. Big-endian bytes of an unsigned 64-bit value sort under memcmp the
   same as the value itself; signed int64s do not, because two's-complement
   negatives have the top bit set. XORing with min_int (which has only the
   top bit set) flips just that bit, shifting the signed range [min_int,
   max_int] onto the unsigned range [0, 2^64 - 1]. The mapping is its own
   inverse, so the same function serves encode and decode. *)
let signed_to_unsigned_order value = Int64.logxor value Int64.min_int

let encode_int64_key value =
  let buffer = Bytes.create 8 in
  Bytes.set_int64_be buffer 0 (signed_to_unsigned_order value);
  Bytes.unsafe_to_string buffer

let decode_int64_key bytes =
  if String.length bytes <> 8 then
    invalid_arg
      (Printf.sprintf "Encoding.decode_int64_key: expected 8 bytes, got %d"
         (String.length bytes));
  signed_to_unsigned_order (String.get_int64_be bytes 0)

let encode_row_value values = Marshal.to_string (values : Scalar.data list) []
let decode_row_value bytes : Scalar.data list = Marshal.from_string bytes 0
