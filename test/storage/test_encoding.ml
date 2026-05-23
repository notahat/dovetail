(** Tests for [Encoding]. *)

open Dovetail_core
module Storage = Dovetail_storage

let test_int64_key_round_trip () =
  let inputs =
    [ Int64.min_int; -1L; 0L; 1L; Int64.max_int; 42L; -42L; 1234567890L ]
  in
  List.iter
    (fun original ->
      let encoded = Storage.Encoding.encode_int64_key original in
      let decoded = Storage.Encoding.decode_int64_key encoded in
      Alcotest.(check int64)
        (Printf.sprintf "%Ld round-trips" original)
        original decoded)
    inputs

let test_int64_key_is_byte_comparable () =
  let pairs =
    [
      (Int64.min_int, Int64.max_int);
      (-1000L, -1L);
      (-1L, 0L);
      (0L, 1L);
      (1L, 1000L);
      (-100L, 100L);
    ]
  in
  List.iter
    (fun (smaller, larger) ->
      let encoded_smaller = Storage.Encoding.encode_int64_key smaller in
      let encoded_larger = Storage.Encoding.encode_int64_key larger in
      Alcotest.(check bool)
        (Printf.sprintf "encoded %Ld < encoded %Ld" smaller larger)
        true
        (String.compare encoded_smaller encoded_larger < 0))
    pairs

let test_int64_key_is_eight_bytes () =
  Alcotest.(check int)
    "eight bytes" 8
    (String.length (Storage.Encoding.encode_int64_key 0L))

let test_decode_int64_key_rejects_wrong_length () =
  Alcotest.check_raises "seven bytes"
    (Invalid_argument "Encoding.decode_int64_key: expected 8 bytes, got 7")
    (fun () -> ignore (Storage.Encoding.decode_int64_key "1234567"))

let test_row_value_round_trip () =
  let values : Value.data list =
    [ Int64 42L; String "hello"; Bool true; Int64 (-1L); Bool false ]
  in
  let encoded = Storage.Encoding.encode_row_value values in
  let decoded = Storage.Encoding.decode_row_value encoded in
  Alcotest.(check bool) "decoded equals original" true (decoded = values)

let test_row_value_round_trip_empty () =
  let encoded = Storage.Encoding.encode_row_value [] in
  let decoded = Storage.Encoding.decode_row_value encoded in
  Alcotest.(check bool) "empty list round-trips" true (decoded = [])

let () =
  Alcotest.run "encoding"
    [
      ( "int64 key",
        [
          Alcotest.test_case "round-trips a range of values" `Quick
            test_int64_key_round_trip;
          Alcotest.test_case "encoded order matches numeric order" `Quick
            test_int64_key_is_byte_comparable;
          Alcotest.test_case "encoding is exactly eight bytes" `Quick
            test_int64_key_is_eight_bytes;
          Alcotest.test_case "decoding rejects inputs of the wrong length"
            `Quick test_decode_int64_key_rejects_wrong_length;
        ] );
      ( "row value",
        [
          Alcotest.test_case "round-trips a mixed list" `Quick
            test_row_value_round_trip;
          Alcotest.test_case "round-trips an empty list" `Quick
            test_row_value_round_trip_empty;
        ] );
    ]
