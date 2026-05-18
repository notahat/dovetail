(** Tests for [Statement].

    Covers the pure parts of the DDL AST: [classify] for each constructor (the
    read/write routing decision that drives transaction selection in the REPL),
    and [of_schema] (the adapter from a stored [Schema.t] back to a
    [Create_table]-shaped statement, used by the describe renderer to feed the
    canonical-form printer). The constructor surface itself is exercised through
    the parser ({!Test_parser}) and the executor ({!Test_ddl_executor}); this
    file pins the structural behaviour that lives in [Statement] alone. *)

module Ddl = Dovetail_ddl
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema

let test_list_tables_classifies_as_read () =
  Alcotest.(check bool)
    "List_tables classifies as Read" true
    (Ddl.Statement.classify Ddl.Statement.List_tables = `Read)

let test_drop_table_classifies_as_write () =
  Alcotest.(check bool)
    "Drop_table classifies as Write" true
    (Ddl.Statement.classify (Ddl.Statement.Drop_table { table_name = "users" })
    = `Write)

let test_describe_classifies_as_read () =
  Alcotest.(check bool)
    "Describe classifies as Read" true
    (Ddl.Statement.classify (Ddl.Statement.Describe { table_name = "users" })
    = `Read)

let test_create_table_classifies_as_write () =
  Alcotest.(check bool)
    "Create_table classifies as Write" true
    (Ddl.Statement.classify
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Value.Kind.Int64 } ];
            primary_key = [ "id" ];
          })
    = `Write)

(* A fixture-shaped schema for [users]: every field carries
   [qualifier = Some "users"], matching how [Fixture] and the slice 14
   [Create_table] executor store schemas. *)
let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Value.Kind.Int64; qualifier = Some "users" };
        { name = "name"; kind = Value.Kind.String; qualifier = Some "users" };
        { name = "active"; kind = Value.Kind.Bool; qualifier = Some "users" };
      ];
    primary_key = [ "id" ];
  }

let test_of_schema_strips_qualifiers () =
  let expected : Ddl.Statement.t =
    Create_table
      {
        table_name = "users";
        fields =
          [
            { name = "id"; kind = Value.Kind.Int64 };
            { name = "name"; kind = Value.Kind.String };
            { name = "active"; kind = Value.Kind.Bool };
          ];
        primary_key = [ "id" ];
      }
  in
  Alcotest.(check bool)
    "of_schema produces Create_table with stripped qualifiers" true
    (Ddl.Statement.of_schema ~table_name:"users" users_schema = expected)

let () =
  Alcotest.run "statement"
    [
      ( "classify",
        [
          Alcotest.test_case "List_tables classifies as Read" `Quick
            test_list_tables_classifies_as_read;
          Alcotest.test_case "Drop_table classifies as Write" `Quick
            test_drop_table_classifies_as_write;
          Alcotest.test_case "Describe classifies as Read" `Quick
            test_describe_classifies_as_read;
          Alcotest.test_case "Create_table classifies as Write" `Quick
            test_create_table_classifies_as_write;
        ] );
      ( "of_schema",
        [
          Alcotest.test_case
            "of_schema produces Create_table with stripped qualifiers" `Quick
            test_of_schema_strips_qualifiers;
        ] );
    ]
