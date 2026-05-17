(** Tests for [Ddl].

    Slice 12 step 2 introduces the [Ddl] module and the [List_tables] read path.
    The [Drop_table] statement is defined upfront so the statement universe is
    stable from the start of the slice, but its [execute_write] arm is
    [assert false] until step 5a; tests therefore cover [classify] for both
    constructors and the happy path of [execute_read] on [List_tables]. *)

open Dovetail
open Test_helpers

let users_schema : Schema.t =
  {
    fields = [ { name = "id"; kind = Int64; qualifier = Some "users" } ];
    primary_key = [ "id" ];
  }

let orders_schema : Schema.t =
  {
    fields = [ { name = "id"; kind = Int64; qualifier = Some "orders" } ];
    primary_key = [ "id" ];
  }

let test_list_tables_classifies_as_read () =
  Alcotest.(check bool)
    "List_tables classifies as Read" true
    (Ddl.classify Ddl.List_tables = `Read)

let test_drop_table_classifies_as_write () =
  Alcotest.(check bool)
    "Drop_table classifies as Write" true
    (Ddl.classify (Ddl.Drop_table { table_name = "users" }) = `Write)

let test_execute_read_list_tables_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema;
      Catalog.put environment transaction ~table_name:"orders" orders_schema);
  Storage.with_read_transaction environment (fun transaction ->
      match Ddl.execute_read environment transaction Ddl.List_tables with
      | Listed names ->
          Alcotest.(check (list string))
            "byte-sorted table names" [ "orders"; "users" ] names)

let test_execute_read_list_tables_on_empty_catalog () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      match Ddl.execute_read environment transaction Ddl.List_tables with
      | Listed names ->
          Alcotest.(check (list string))
            "empty list when catalog absent" [] names)

let () =
  Alcotest.run "ddl"
    [
      ( "classify",
        [
          Alcotest.test_case "List_tables classifies as Read" `Quick
            test_list_tables_classifies_as_read;
          Alcotest.test_case "Drop_table classifies as Write" `Quick
            test_drop_table_classifies_as_write;
        ] );
      ( "execute_read",
        [
          Alcotest.test_case "List_tables returns byte-sorted names" `Quick
            test_execute_read_list_tables_returns_byte_sorted_names;
          Alcotest.test_case "List_tables on empty catalog returns []" `Quick
            test_execute_read_list_tables_on_empty_catalog;
        ] );
    ]
