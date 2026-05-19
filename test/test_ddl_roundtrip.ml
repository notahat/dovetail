(** Round-trip property tests for the DDL surface.

    Pins the design's strongest correctness anchor for the DDL surface: for
    every [Statement.t] value [s], parsing the canonical form of [s] yields
    [Ast.Ddl s]. Concretely,
    [Parser.parse (Format.statement s) = Ok (Ast.Ddl s)] holds for each entry of
    the corpus below. If a future parser or printer change breaks the property,
    the test fails before the change reaches downstream code.

    The corpus is hand-rolled (no [qcheck]) and covers one case per constructor:
    [List_tables], [Drop_table], [Describe] for the one-liners, and a small set
    of [Create_table] shapes (each value kind in turn, a compound primary key,
    plus the design doc's [users] and [order_items] canonical examples). *)

open Dovetail_surface_ra
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

let test_round_trip_create_table_int64_pk () =
  check_round_trip
    (Ddl.Statement.Create_table
       {
         table_name = "widgets";
         fields = [ { name = "id"; kind = Value.Kind.Int64 } ];
         primary_key = [ "id" ];
       })

let test_round_trip_create_table_string_pk () =
  check_round_trip
    (Ddl.Statement.Create_table
       {
         table_name = "widgets";
         fields = [ { name = "name"; kind = Value.Kind.String } ];
         primary_key = [ "name" ];
       })

let test_round_trip_create_table_bool_pk () =
  check_round_trip
    (Ddl.Statement.Create_table
       {
         table_name = "widgets";
         fields = [ { name = "active"; kind = Value.Kind.Bool } ];
         primary_key = [ "active" ];
       })

let test_round_trip_create_table_compound_pk () =
  check_round_trip
    (Ddl.Statement.Create_table
       {
         table_name = "pairs";
         fields =
           [
             { name = "left"; kind = Value.Kind.Int64 };
             { name = "right"; kind = Value.Kind.Int64 };
           ];
         primary_key = [ "left"; "right" ];
       })

(* The [users] example from [docs/plans/ddl-design.md]. Same shape as
   the [test_format_create_table_users_example] entry in
   [test/ddl/test_format.ml]; carrying it through the round-trip pins
   the design doc's canonical form against the parser as well as the
   printer. *)
let test_round_trip_create_table_users_example () =
  check_round_trip
    (Ddl.Statement.Create_table
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
       })

(* The [order_items] example from [docs/plans/ddl-design.md]: compound
   primary key. *)
let test_round_trip_create_table_order_items_example () =
  check_round_trip
    (Ddl.Statement.Create_table
       {
         table_name = "order_items";
         fields =
           [
             { name = "order_id"; kind = Value.Kind.Int64 };
             { name = "product_id"; kind = Value.Kind.Int64 };
             { name = "quantity"; kind = Value.Kind.Int64 };
           ];
         primary_key = [ "order_id"; "product_id" ];
       })

let () =
  Alcotest.run "ddl_roundtrip"
    [
      ( "one-liners",
        [
          Alcotest.test_case "List_tables" `Quick test_round_trip_list_tables;
          Alcotest.test_case "Drop_table" `Quick test_round_trip_drop_table;
          Alcotest.test_case "Describe" `Quick test_round_trip_describe;
        ] );
      ( "create table",
        [
          Alcotest.test_case "single Int64 PK" `Quick
            test_round_trip_create_table_int64_pk;
          Alcotest.test_case "single String PK" `Quick
            test_round_trip_create_table_string_pk;
          Alcotest.test_case "single Bool PK" `Quick
            test_round_trip_create_table_bool_pk;
          Alcotest.test_case "compound primary key" `Quick
            test_round_trip_create_table_compound_pk;
        ] );
      ( "design doc examples",
        [
          Alcotest.test_case "users" `Quick
            test_round_trip_create_table_users_example;
          Alcotest.test_case "order_items" `Quick
            test_round_trip_create_table_order_items_example;
        ] );
    ]
