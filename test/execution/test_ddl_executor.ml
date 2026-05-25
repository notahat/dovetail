(** Tests for [Ddl_executor].

    Today's only DDL statement [:list tables] runs through [execute_read].
    Covers the happy path against a populated catalog and the empty-catalog
    edge. *)

open Dovetail_execution
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation
module Ddl = Dovetail_ddl
module Storage = Dovetail_storage

let users_kind : Relation.kind =
  {
    row_kind =
      [ { name = "id"; kind = Scalar.Int64; qualifier = Some "users" } ];
    refinements = [ Primary_key [ "id" ] ];
  }

let orders_kind : Relation.kind =
  {
    row_kind =
      [ { name = "id"; kind = Scalar.Int64; qualifier = Some "orders" } ];
    refinements = [ Primary_key [ "id" ] ];
  }

let test_execute_read_list_tables_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      Storage.Catalog.put environment transaction ~table_name:"orders"
        orders_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_read environment transaction
          Ddl.Statement.List_tables
      with
      | Listed names ->
          Alcotest.(check (list string))
            "byte-sorted table names" [ "orders"; "users" ] names)

let test_execute_read_list_tables_on_empty_catalog () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_read_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_read environment transaction
          Ddl.Statement.List_tables
      with
      | Listed names ->
          Alcotest.(check (list string))
            "empty list when catalog absent" [] names)

let () =
  Alcotest.run "ddl_executor"
    [
      ( "execute_read",
        [
          Alcotest.test_case "List_tables returns byte-sorted names" `Quick
            test_execute_read_list_tables_returns_byte_sorted_names;
          Alcotest.test_case "List_tables on empty catalog returns []" `Quick
            test_execute_read_list_tables_on_empty_catalog;
        ] );
    ]
