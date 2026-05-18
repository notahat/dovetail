(** Round-trip property tests for the DDL surface.

    Pins the design's strongest correctness anchor for the DDL surface: for
    every [Statement.t] value [s], parsing the canonical form of [s] yields
    [Ast.Ddl s]. Concretely,
    [Parser.parse (Format.statement s) = Ok (Ast.Ddl s)] holds for each entry of
    the corpus below. If a future parser or printer change breaks the property,
    the test fails before the change reaches downstream code.

    The corpus is hand-rolled (no [qcheck]) and covers one case per
    non-[Create_table] constructor today. [Create_table] cases are populated as
    dormant stubs in {!pending_create_table_corpus}; slice 14 step 5 (parser for
    [:create table]) turns them on by moving them into the active corpus. *)

open Dovetail
module Ddl = Dovetail_ddl
module Value = Dovetail_core.Value

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
   [Ast.Ddl] wrapping the same statement value. A parse error or a
   [Ast.Pipeline] result is a failed round trip and reports the formatted
   text in the failure message so the offending shape is visible. *)
let check_round_trip (statement : Ddl.Statement.t) =
  let formatted = Ddl.Format.statement statement in
  match Parser.parse formatted with
  | Ok (Ast.Ddl parsed_statement) ->
      Alcotest.check statement_testable
        (Printf.sprintf
           "round-trip preserves the statement value (formatted: %S)" formatted)
        statement parsed_statement
  | Ok (Ast.Pipeline _) ->
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

let test_round_trip_drop_table () =
  check_round_trip (Ddl.Statement.Drop_table { table_name = "widgets" })

let test_round_trip_describe () =
  check_round_trip (Ddl.Statement.Describe { table_name = "widgets" })

(* Dormant corpus for [:create table]. Slice 14 step 5 admits these
   shapes at the parser level, at which point the cases here move into
   active [test_round_trip_create_table_*] functions below. Kept as a
   bound value (rather than a comment) so the corpus stays in code form
   -- step 5's change is "promote entries", not "transcribe a comment." *)
let _pending_create_table_corpus : Ddl.Statement.t list =
  [
    Ddl.Statement.Create_table
      {
        table_name = "widgets";
        fields = [ { name = "id"; kind = Value.Kind.Int64 } ];
        primary_key = [ "id" ];
      };
    Ddl.Statement.Create_table
      {
        table_name = "users";
        fields =
          [
            { name = "id"; kind = Value.Kind.Int64 };
            { name = "name"; kind = Value.Kind.String };
            { name = "email"; kind = Value.Kind.String };
            { name = "active"; kind = Value.Kind.Bool };
          ];
        primary_key = [ "id" ];
      };
    Ddl.Statement.Create_table
      {
        table_name = "order_items";
        fields =
          [
            { name = "order_id"; kind = Value.Kind.Int64 };
            { name = "product_id"; kind = Value.Kind.Int64 };
            { name = "quantity"; kind = Value.Kind.Int64 };
          ];
        primary_key = [ "order_id"; "product_id" ];
      };
  ]

let () =
  Alcotest.run "ddl_roundtrip"
    [
      ( "supported constructors",
        [
          Alcotest.test_case "List_tables" `Quick test_round_trip_list_tables;
          Alcotest.test_case "Drop_table" `Quick test_round_trip_drop_table;
          Alcotest.test_case "Describe" `Quick test_round_trip_describe;
        ] );
    ]
