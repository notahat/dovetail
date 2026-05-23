(** Round-trip property tests for scalar values.

    The type-system design (see [docs/type-system.md]) treats round-tripping
    between the printer and the parser as a first-class property of every rung
    of the value/type ladder. This file pins the property at the scalar rung:
    for each [Scalar.value] [s] in a hand-rolled corpus, parsing the output of
    [Scalar.format s] yields an [Expression.Literal s] back.

    The parser surface for a bare scalar today is [Parser.parse_expression] -- a
    literal is a valid standalone atom in the expression sublanguage. When the
    type-system note's wider [name = value] / pipe-based literal syntax lands,
    the same corpus should round-trip through whatever new entry point parses a
    bare value; the test below is the anchor that will be updated alongside that
    change.

    Cases known not to round-trip today are deliberately omitted: strings
    containing a double quote or a backslash break because [Scalar.format] emits
    them verbatim while the parser only accepts the backslash-quote and
    backslash-backslash escape forms. The mismatch is documented in
    [Scalar.format]'s [.mli] and called out as an open question in
    [docs/type-system.md]. *)

open Dovetail_surface_ra
module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression

(* Polymorphic equality is safe for [Scalar.value] -- it is a plain
   algebraic data type. The printer in the testable mirrors [Scalar.format]
   so failure messages show the value in the same form that flowed through
   the parser. *)
let scalar_testable =
  Alcotest.testable
    (fun formatter value ->
      Format.fprintf formatter "%s" (Scalar.to_string value))
    ( = )

(* Format a scalar, parse the result as a standalone expression, and assert
   the parser produced an [Expression.Literal] wrapping the same scalar
   value. A parse error, or a non-[Literal] expression, is a failed round
   trip and surfaces the formatted text so the offending shape is visible. *)
let check_round_trip (value : Scalar.value) =
  let formatted = Scalar.to_string value in
  match Parser.parse_expression formatted with
  | Ok (Expression.Literal parsed_value) ->
      Alcotest.check scalar_testable
        (Printf.sprintf "round-trip preserves the scalar value (formatted: %S)"
           formatted)
        value parsed_value
  | Ok other_expression ->
      Alcotest.failf
        "round-trip parsed to a non-literal expression\n\
         formatted: %S\n\
         parsed kind: %s"
        formatted
        (match other_expression with
        | Expression.Literal _ -> "Literal"
        | Expression.Column _ -> "Column"
        | Expression.Compare _ -> "Compare"
        | Expression.And _ -> "And"
        | Expression.Or _ -> "Or"
        | Expression.Not _ -> "Not")
  | Error message ->
      Alcotest.failf
        "round-trip failed to parse the formatted text\n\
         formatted: %S\n\
         parse error: %s"
        formatted message

let test_round_trip_int64_positive () = check_round_trip (Scalar.Int64 42L)
let test_round_trip_int64_negative () = check_round_trip (Scalar.Int64 (-7L))
let test_round_trip_int64_zero () = check_round_trip (Scalar.Int64 0L)
let test_round_trip_int64_max () = check_round_trip (Scalar.Int64 Int64.max_int)
let test_round_trip_int64_min () = check_round_trip (Scalar.Int64 Int64.min_int)
let test_round_trip_string_simple () = check_round_trip (Scalar.String "Alice")
let test_round_trip_string_empty () = check_round_trip (Scalar.String "")

let test_round_trip_string_with_spaces () =
  check_round_trip (Scalar.String "hello world")

let test_round_trip_bool_true () = check_round_trip (Scalar.Bool true)
let test_round_trip_bool_false () = check_round_trip (Scalar.Bool false)

let () =
  Alcotest.run "scalar round-trip"
    [
      ( "int64",
        [
          Alcotest.test_case "positive" `Quick test_round_trip_int64_positive;
          Alcotest.test_case "negative" `Quick test_round_trip_int64_negative;
          Alcotest.test_case "zero" `Quick test_round_trip_int64_zero;
          Alcotest.test_case "Int64.max_int" `Quick test_round_trip_int64_max;
          Alcotest.test_case "Int64.min_int" `Quick test_round_trip_int64_min;
        ] );
      ( "string",
        [
          Alcotest.test_case "simple ASCII" `Quick test_round_trip_string_simple;
          Alcotest.test_case "empty" `Quick test_round_trip_string_empty;
          Alcotest.test_case "with spaces" `Quick
            test_round_trip_string_with_spaces;
        ] );
      ( "bool",
        [
          Alcotest.test_case "true" `Quick test_round_trip_bool_true;
          Alcotest.test_case "false" `Quick test_round_trip_bool_false;
        ] );
    ]
