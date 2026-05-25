(** Tests for [Ddl_executor].

    Covers [execute_read] on [List_tables] (happy path and the empty-catalog
    edge), and [execute_write] on [Drop_table] (catalog and storage state after
    a successful drop, sibling tables untouched, and the catalog-aware "no such
    table" error). [Ddl_executor.execute_write] is reached directly here rather
    than through the REPL so the failure-mode assertions can pin both the raised
    wording and the post-abort state in one place. *)

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

let kind_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<kind>")) ( = )

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

(* Seed [environment] with a single table named [table_name]: a catalog
   entry under [kind] and a storage subDB with one row, so Drop_table
   has both halves to remove. The row contents are irrelevant -- the
   storage drop empties the subDB whether it has rows or not. *)
let seed_table environment ~table_name kind =
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name kind;
      let map =
        Storage.Engine.create_map environment transaction
          ~name:(Storage.Catalog.table_subdb_name table_name)
      in
      Storage.Engine.put map transaction ~key:"any-key" ~value:"any-value")

let test_execute_write_drop_table_removes_catalog_and_storage () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_kind;
  Storage.Engine.with_write_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_write environment transaction
          (Ddl.Statement.Drop_table { table_name = "users" })
      with
      | Dropped name ->
          Alcotest.(check string) "result names the dropped table" "users" name);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "catalog entry gone" None
        (Storage.Catalog.get environment transaction ~table_name:"users");
      Alcotest.(check bool)
        "storage subDB gone" true
        (Storage.Engine.open_map environment transaction
           ~name:(Storage.Catalog.table_subdb_name "users")
        = None))

let test_execute_write_drop_table_leaves_sibling_tables_untouched () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_kind;
  seed_table environment ~table_name:"orders" orders_kind;
  Storage.Engine.with_write_transaction environment (fun transaction ->
      let _result =
        Ddl_executor.execute_write environment transaction
          (Ddl.Statement.Drop_table { table_name = "users" })
      in
      ());
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "orders catalog entry preserved" (Some orders_kind)
        (Storage.Catalog.get environment transaction ~table_name:"orders");
      Alcotest.(check bool)
        "orders storage subDB preserved" true
        (Storage.Engine.open_map environment transaction
           ~name:(Storage.Catalog.table_subdb_name "orders")
        <> None))

let test_execute_write_drop_table_no_such_table_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_kind;
  Alcotest.check_raises "no such table raises Failure with DDL: prefix"
    (Failure "DDL: drop table \"nonexistent\": no such table") (fun () ->
      Storage.Engine.with_write_transaction environment (fun transaction ->
          let _result =
            Ddl_executor.execute_write environment transaction
              (Ddl.Statement.Drop_table { table_name = "nonexistent" })
          in
          ()));
  (* The aborted transaction must not have touched the seeded table. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "users still present after aborted drop" (Some users_kind)
        (Storage.Catalog.get environment transaction ~table_name:"users"))

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
      ( "execute_write",
        [
          Alcotest.test_case
            "Drop_table removes the catalog entry and storage subDB" `Quick
            test_execute_write_drop_table_removes_catalog_and_storage;
          Alcotest.test_case "Drop_table leaves sibling tables untouched" `Quick
            test_execute_write_drop_table_leaves_sibling_tables_untouched;
          Alcotest.test_case "Drop_table on a missing table raises Failure"
            `Quick test_execute_write_drop_table_no_such_table_raises;
        ] );
    ]
