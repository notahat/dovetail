(** Round-trip property tests for the DDL surface.

    For every [Statement.t] value [s], parsing the canonical form of [s] yields
    [Ast.Ddl s]. Today the corpus is just [List_tables]; the property is
    preserved here against future expansion of [Statement.t]. *)

module Surface_ra = Dovetail_surface_ra
module Ddl = Dovetail_ddl

(* Polymorphic equality is safe for [Ddl.Statement.t] -- the type is a
   plain algebraic data type with no functional or abstract components.
   The printer is the diagnostic on failure: the formatted text is what
   the parser sees, so showing it directly names the input under test. *)
let statement_testable =
  Alcotest.testable
    (fun formatter statement ->
      Format.fprintf formatter "%s" (Ddl.Format.statement statement))
    ( = )

(* Format a statement, parse the result, and assert the parser produced
   [Ast.Ddl] wrapping the same statement value. *)
let check_round_trip (statement : Ddl.Statement.t) =
  let formatted = Ddl.Format.statement statement in
  match Surface_ra.Parser.parse formatted with
  | Ok (Surface_ra.Ast.Ddl parsed_statement) ->
      Alcotest.check statement_testable
        (Printf.sprintf
           "round-trip preserves the statement value (formatted: %S)" formatted)
        statement parsed_statement
  | Ok (Surface_ra.Ast.Pipeline _) ->
      Alcotest.failf
        "round-trip produced a pipeline, expected a DDL statement\n\
         formatted text: %S"
        formatted
  | Error message ->
      Alcotest.failf
        "round-trip failed to parse the formatted text\n\
         formatted: %S\n\
         parse error: %s"
        formatted message

let test_round_trip_list_tables () = check_round_trip Ddl.Statement.List_tables

let () =
  Alcotest.run "ddl_roundtrip"
    [
      ( "one-liners",
        [ Alcotest.test_case "List_tables" `Quick test_round_trip_list_tables ]
      );
    ]
