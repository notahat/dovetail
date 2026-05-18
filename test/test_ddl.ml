(** Tests for [Ddl].

    Covers the slice-12 universe: [classify] for both statement constructors,
    [execute_read] on [List_tables] (happy path and the empty-catalog edge), and
    [execute_write] on [Drop_table] (catalog and storage state after a
    successful drop, sibling tables untouched, and the catalog-aware "no such
    table" error). [Ddl.execute_write] is reached directly here rather than
    through the REPL so the failure-mode assertions can pin both the raised
    wording and the post-abort state in one place. *)

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

let schema_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<schema>")) ( = )

let test_list_tables_classifies_as_read () =
  Alcotest.(check bool)
    "List_tables classifies as Read" true
    (Statement.classify Statement.List_tables = `Read)

let test_drop_table_classifies_as_write () =
  Alcotest.(check bool)
    "Drop_table classifies as Write" true
    (Statement.classify (Statement.Drop_table { table_name = "users" }) = `Write)

let test_execute_read_list_tables_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema;
      Catalog.put environment transaction ~table_name:"orders" orders_schema);
  Storage.with_read_transaction environment (fun transaction ->
      match Ddl.execute_read environment transaction Statement.List_tables with
      | Listed names ->
          Alcotest.(check (list string))
            "byte-sorted table names" [ "orders"; "users" ] names)

let test_execute_read_list_tables_on_empty_catalog () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_read_transaction environment (fun transaction ->
      match Ddl.execute_read environment transaction Statement.List_tables with
      | Listed names ->
          Alcotest.(check (list string))
            "empty list when catalog absent" [] names)

(* Seed [environment] with a single table named [table_name]: a catalog
   entry under [schema] and a storage subDB with one row, so Drop_table
   has both halves to remove. The row contents are irrelevant -- the
   storage drop empties the subDB whether it has rows or not. *)
let seed_table environment ~table_name schema =
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name schema;
      let map =
        Storage.create_map environment transaction
          ~name:(Catalog.table_subdb_name table_name)
      in
      Storage.put map transaction ~key:"any-key" ~value:"any-value")

let test_execute_write_drop_table_removes_catalog_and_storage () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_schema;
  Storage.with_write_transaction environment (fun transaction ->
      match
        Ddl.execute_write environment transaction
          (Statement.Drop_table { table_name = "users" })
      with
      | Dropped name ->
          Alcotest.(check string) "result names the dropped table" "users" name);
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "catalog entry gone" None
        (Catalog.get environment transaction ~table_name:"users");
      Alcotest.(check bool)
        "storage subDB gone" true
        (Storage.open_map environment transaction
           ~name:(Catalog.table_subdb_name "users")
        = None))

let test_execute_write_drop_table_leaves_sibling_tables_untouched () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_schema;
  seed_table environment ~table_name:"orders" orders_schema;
  Storage.with_write_transaction environment (fun transaction ->
      let _result =
        Ddl.execute_write environment transaction
          (Statement.Drop_table { table_name = "users" })
      in
      ());
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "orders catalog entry preserved" (Some orders_schema)
        (Catalog.get environment transaction ~table_name:"orders");
      Alcotest.(check bool)
        "orders storage subDB preserved" true
        (Storage.open_map environment transaction
           ~name:(Catalog.table_subdb_name "orders")
        <> None))

let test_execute_write_drop_table_no_such_table_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_schema;
  Alcotest.check_raises "no such table raises Failure with module prefix"
    (Failure "Ddl: drop table \"nonexistent\": no such table") (fun () ->
      Storage.with_write_transaction environment (fun transaction ->
          let _result =
            Ddl.execute_write environment transaction
              (Statement.Drop_table { table_name = "nonexistent" })
          in
          ()));
  (* The aborted transaction must not have touched the seeded table. *)
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "users still present after aborted drop" (Some users_schema)
        (Catalog.get environment transaction ~table_name:"users"))

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
