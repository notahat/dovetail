(* XOR mask that flips the sign bit of an int64. Applying it before a
   big-endian write makes negatives sort below positives under memcmp. *)
let int64_sign_flip = 0x8000000000000000L

let encode_int64_key value =
  let flipped = Int64.logxor value int64_sign_flip in
  let buffer = Bytes.create 8 in
  Bytes.set_int64_be buffer 0 flipped;
  Bytes.unsafe_to_string buffer

let decode_int64_key bytes =
  if String.length bytes <> 8 then
    invalid_arg
      (Printf.sprintf "Encoding.decode_int64_key: expected 8 bytes, got %d"
         (String.length bytes));
  let flipped = String.get_int64_be bytes 0 in
  Int64.logxor flipped int64_sign_flip

let encode_tuple_value values = Marshal.to_string (values : Value.t list) []
let decode_tuple_value bytes : Value.t list = Marshal.from_string bytes 0
