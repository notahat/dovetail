(** Tests for [Statement].

    Covers the pure parts of the DDL AST: [classify] for each constructor (the
    read/write routing decision that drives transaction selection in the REPL)
    and [validate] (structural checks against [Create_table] shapes). The
    constructor surface itself is exercised through the parser ({!Test_parser})
    and the executor ({!Test_ddl_executor}); this file pins the structural
    behaviour that lives in [Statement] alone. *)

module Ddl = Dovetail_ddl
module Scalar = Dovetail_core.Scalar

let test_list_tables_classifies_as_read () =
  Alcotest.(check bool)
    "List_tables classifies as Read" true
    (Ddl.Statement.classify Ddl.Statement.List_tables = `Read)

let test_drop_table_classifies_as_write () =
  Alcotest.(check bool)
    "Drop_table classifies as Write" true
    (Ddl.Statement.classify (Ddl.Statement.Drop_table { table_name = "users" })
    = `Write)

let test_create_table_classifies_as_write () =
  Alcotest.(check bool)
    "Create_table classifies as Write" true
    (Ddl.Statement.classify
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Scalar.Int64 } ];
            primary_key = [ "id" ];
          })
    = `Write)

(* Build a [Create_table] statement for [table_name] with the given [fields]
   and [primary_key]. The fields default to the well-formed [(id: Int64,
   name: String)] pair so per-test overrides only need to spell out the
   shape they are exercising. *)
let make_create_table ?(table_name = "widgets")
    ?(fields : Ddl.Statement.field list =
      [
        { name = "id"; kind = Scalar.Int64 };
        { name = "name"; kind = Scalar.String };
      ]) ?(primary_key = [ "id" ]) () : Ddl.Statement.t =
  Create_table { table_name; fields; primary_key }

let validate_result = Alcotest.result Alcotest.unit Alcotest.string

let test_validate_well_formed_create_table_returns_ok () =
  Alcotest.(check validate_result)
    "well-formed Create_table is Ok ()" (Ok ())
    (Ddl.Statement.validate (make_create_table ()))

let test_validate_rejects_empty_column_list () =
  Alcotest.(check validate_result)
    "empty column list is rejected"
    (Error "DDL: create table \"widgets\": column list is empty")
    (Ddl.Statement.validate
       (make_create_table ~fields:[] ~primary_key:[ "id" ] ()))

let test_validate_rejects_duplicate_column () =
  Alcotest.(check validate_result)
    "duplicate column is rejected"
    (Error "DDL: create table \"widgets\": column \"email\" appears twice")
    (Ddl.Statement.validate
       (make_create_table
          ~fields:
            [
              { name = "id"; kind = Scalar.Int64 };
              { name = "email"; kind = Scalar.String };
              { name = "email"; kind = Scalar.String };
            ]
          ~primary_key:[ "id" ] ()))

let test_validate_rejects_empty_primary_key () =
  Alcotest.(check validate_result)
    "empty primary key is rejected"
    (Error "DDL: create table \"widgets\": primary key is empty")
    (Ddl.Statement.validate (make_create_table ~primary_key:[] ()))

let test_validate_rejects_primary_key_column_not_in_fields () =
  Alcotest.(check validate_result)
    "primary key column missing from column list is rejected"
    (Error
       "DDL: create table \"widgets\": primary key column \"missing\" not in \
        column list")
    (Ddl.Statement.validate (make_create_table ~primary_key:[ "missing" ] ()))

let test_validate_rejects_duplicate_primary_key_column () =
  Alcotest.(check validate_result)
    "duplicate primary key column is rejected"
    (Error
       "DDL: create table \"widgets\": primary key column \"id\" appears twice")
    (Ddl.Statement.validate (make_create_table ~primary_key:[ "id"; "id" ] ()))

let test_validate_passes_non_create_table_constructors () =
  Alcotest.(check validate_result)
    "List_tables is Ok ()" (Ok ())
    (Ddl.Statement.validate Ddl.Statement.List_tables);
  Alcotest.(check validate_result)
    "Drop_table is Ok ()" (Ok ())
    (Ddl.Statement.validate (Ddl.Statement.Drop_table { table_name = "users" }))

let () =
  Alcotest.run "statement"
    [
      ( "classify",
        [
          Alcotest.test_case "List_tables classifies as Read" `Quick
            test_list_tables_classifies_as_read;
          Alcotest.test_case "Drop_table classifies as Write" `Quick
            test_drop_table_classifies_as_write;
          Alcotest.test_case "Create_table classifies as Write" `Quick
            test_create_table_classifies_as_write;
        ] );
      ( "validate",
        [
          Alcotest.test_case "well-formed Create_table is Ok ()" `Quick
            test_validate_well_formed_create_table_returns_ok;
          Alcotest.test_case "empty column list is rejected" `Quick
            test_validate_rejects_empty_column_list;
          Alcotest.test_case "duplicate column in column list is rejected"
            `Quick test_validate_rejects_duplicate_column;
          Alcotest.test_case "empty primary key is rejected" `Quick
            test_validate_rejects_empty_primary_key;
          Alcotest.test_case "primary key column not in column list is rejected"
            `Quick test_validate_rejects_primary_key_column_not_in_fields;
          Alcotest.test_case "duplicate primary key column is rejected" `Quick
            test_validate_rejects_duplicate_primary_key_column;
          Alcotest.test_case "non-Create_table constructors are Ok ()" `Quick
            test_validate_passes_non_create_table_constructors;
        ] );
    ]
