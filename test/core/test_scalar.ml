(** Tests for [Scalar.format] and [Scalar.to_string], the canonical source-like
    renderer for runtime values. *)

open Dovetail_core

(* Render via [Scalar.format] into a string so the tests can compare against
   the expected source text. *)
let format_to_string value =
  let buffer = Buffer.create 32 in
  let formatter = Format.formatter_of_buffer buffer in
  Scalar.format formatter value;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_int64_renders_bare_digits () =
  Alcotest.(check string)
    "positive int64 has no decoration" "42"
    (format_to_string (Scalar.Int64 42L));
  Alcotest.(check string)
    "negative int64 keeps its sign" "-7"
    (format_to_string (Scalar.Int64 (-7L)));
  Alcotest.(check string)
    "zero renders as 0" "0"
    (format_to_string (Scalar.Int64 0L))

let test_format_string_quotes_with_double_quotes () =
  Alcotest.(check string)
    "non-empty string is wrapped in double quotes" {|"Alice"|}
    (format_to_string (Scalar.String "Alice"));
  Alcotest.(check string)
    "empty string renders as a bare quote pair" {|""|}
    (format_to_string (Scalar.String ""))

let test_format_bool_renders_lowercase_keywords () =
  Alcotest.(check string)
    "true keyword" "true"
    (format_to_string (Scalar.Bool true));
  Alcotest.(check string)
    "false keyword" "false"
    (format_to_string (Scalar.Bool false))

let test_to_string_matches_format_output () =
  Alcotest.(check string)
    "Int64"
    (format_to_string (Scalar.Int64 42L))
    (Scalar.to_string (Scalar.Int64 42L));
  Alcotest.(check string)
    "String"
    (format_to_string (Scalar.String "Alice"))
    (Scalar.to_string (Scalar.String "Alice"));
  Alcotest.(check string)
    "Bool"
    (format_to_string (Scalar.Bool true))
    (Scalar.to_string (Scalar.Bool true))

let () =
  Alcotest.run "value"
    [
      ( "format",
        [
          Alcotest.test_case "Int64 renders as bare digits" `Quick
            test_format_int64_renders_bare_digits;
          Alcotest.test_case "String is wrapped in double quotes" `Quick
            test_format_string_quotes_with_double_quotes;
          Alcotest.test_case "Bool renders as the lowercase keyword" `Quick
            test_format_bool_renders_lowercase_keywords;
        ] );
      ( "to_string",
        [
          Alcotest.test_case "matches the Format.formatter output across kinds"
            `Quick test_to_string_matches_format_output;
        ] );
    ]
