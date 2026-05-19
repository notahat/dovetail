(** Tests for [Ddl_executor].

    Covers [execute_read] on [List_tables] (happy path and the empty-catalog
    edge), and [execute_write] on [Drop_table] (catalog and storage state after
    a successful drop, sibling tables untouched, and the catalog-aware "no such
    table" error). [Ddl_executor.execute_write] is reached directly here rather
    than through the REPL so the failure-mode assertions can pin both the raised
    wording and the post-abort state in one place. *)

open Dovetail_execution
open Test_helpers
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
module Ddl = Dovetail_ddl
module Storage = Dovetail_storage

let users_schema : Schema.t =
  {
    fields =
      [ { name = "id"; kind = Value.Kind.Int64; qualifier = Some "users" } ];
    primary_key = [ "id" ];
  }

let orders_schema : Schema.t =
  {
    fields =
      [ { name = "id"; kind = Value.Kind.Int64; qualifier = Some "orders" } ];
    primary_key = [ "id" ];
  }

let schema_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<schema>")) ( = )

let test_execute_read_list_tables_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users"
        users_schema;
      Storage.Catalog.put environment transaction ~table_name:"orders"
        orders_schema);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_read environment transaction
          Ddl.Statement.List_tables
      with
      | Listed names ->
          Alcotest.(check (list string))
            "byte-sorted table names" [ "orders"; "users" ] names
      | Described _ ->
          (* List_tables produces Listed, never Described. *)
          assert false)

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
            "empty list when catalog absent" [] names
      | Described _ ->
          (* List_tables produces Listed, never Described. *)
          assert false)

let test_execute_read_describe_returns_stored_schema () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users"
        users_schema);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_read environment transaction
          (Ddl.Statement.Describe { table_name = "users" })
      with
      | Described { table_name; schema } ->
          Alcotest.(check string)
            "result names the described table" "users" table_name;
          Alcotest.(check schema_testable)
            "result carries the stored schema" users_schema schema
      | Listed _ ->
          (* Describe produces Described, never Listed. *)
          assert false)

let test_execute_read_describe_no_such_table_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Alcotest.check_raises "no such table raises Failure with DDL: prefix"
    (Failure "DDL: describe \"nonexistent\": no such table") (fun () ->
      Storage.Engine.with_read_transaction environment (fun transaction ->
          let _result =
            Ddl_executor.execute_read environment transaction
              (Ddl.Statement.Describe { table_name = "nonexistent" })
          in
          ()))

(* Seed [environment] with a single table named [table_name]: a catalog
   entry under [schema] and a storage subDB with one row, so Drop_table
   has both halves to remove. The row contents are irrelevant -- the
   storage drop empties the subDB whether it has rows or not. *)
let seed_table environment ~table_name schema =
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name schema;
      let map =
        Storage.Engine.create_map environment transaction
          ~name:(Storage.Catalog.table_subdb_name table_name)
      in
      Storage.Engine.put map transaction ~key:"any-key" ~value:"any-value")

let test_execute_write_drop_table_removes_catalog_and_storage () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_schema;
  Storage.Engine.with_write_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_write environment transaction
          (Ddl.Statement.Drop_table { table_name = "users" })
      with
      | Dropped name ->
          Alcotest.(check string) "result names the dropped table" "users" name
      | Created _ ->
          (* Drop_table produces Dropped, never Created. *)
          assert false);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
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
  seed_table environment ~table_name:"users" users_schema;
  seed_table environment ~table_name:"orders" orders_schema;
  Storage.Engine.with_write_transaction environment (fun transaction ->
      let _result =
        Ddl_executor.execute_write environment transaction
          (Ddl.Statement.Drop_table { table_name = "users" })
      in
      ());
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "orders catalog entry preserved" (Some orders_schema)
        (Storage.Catalog.get environment transaction ~table_name:"orders");
      Alcotest.(check bool)
        "orders storage subDB preserved" true
        (Storage.Engine.open_map environment transaction
           ~name:(Storage.Catalog.table_subdb_name "orders")
        <> None))

let test_execute_write_drop_table_no_such_table_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"users" users_schema;
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
      Alcotest.(check (option schema_testable))
        "users still present after aborted drop" (Some users_schema)
        (Storage.Catalog.get environment transaction ~table_name:"users"))

(* The canonical [widgets] statement reused by the [Create_table] cases:
   a single Int64 primary key with no other columns. Hand-built so the
   test exercises the executor arm directly, without going through the
   parser. *)
let widgets_create_statement : Ddl.Statement.t =
  Create_table
    {
      table_name = "widgets";
      fields = [ { name = "id"; kind = Value.Kind.Int64 } ];
      primary_key = [ "id" ];
    }

(* The schema [Create_table widgets ...] should write into the catalog:
   the column qualifier is set to [Some "widgets"] so the read path can
   treat it the same as any fixture-seeded schema. *)
let widgets_expected_schema : Schema.t =
  {
    fields =
      [ { name = "id"; kind = Value.Kind.Int64; qualifier = Some "widgets" } ];
    primary_key = [ "id" ];
  }

let test_execute_write_create_table_writes_catalog_and_storage () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      match
        Ddl_executor.execute_write environment transaction
          widgets_create_statement
      with
      | Created name ->
          Alcotest.(check string)
            "result names the created table" "widgets" name
      | Dropped _ ->
          (* Create_table produces Created, never Dropped. *)
          assert false);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "catalog entry written with qualifier set"
        (Some widgets_expected_schema)
        (Storage.Catalog.get environment transaction ~table_name:"widgets");
      Alcotest.(check bool)
        "storage subDB created" true
        (Storage.Engine.open_map environment transaction
           ~name:(Storage.Catalog.table_subdb_name "widgets")
        <> None))

let test_execute_write_create_table_qualifier_per_field () =
  (* A wider statement so the qualifier rule is checked against more
     than the lone primary-key column. *)
  let statement : Ddl.Statement.t =
    Create_table
      {
        table_name = "widgets";
        fields =
          [
            { name = "id"; kind = Value.Kind.Int64 };
            { name = "name"; kind = Value.Kind.String };
            { name = "active"; kind = Value.Kind.Bool };
          ];
        primary_key = [ "id" ];
      }
  in
  let expected_schema : Schema.t =
    {
      fields =
        [
          { name = "id"; kind = Value.Kind.Int64; qualifier = Some "widgets" };
          {
            name = "name";
            kind = Value.Kind.String;
            qualifier = Some "widgets";
          };
          {
            name = "active";
            kind = Value.Kind.Bool;
            qualifier = Some "widgets";
          };
        ];
      primary_key = [ "id" ];
    }
  in
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      let _ = Ddl_executor.execute_write environment transaction statement in
      ());
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "qualifier set on every field" (Some expected_schema)
        (Storage.Catalog.get environment transaction ~table_name:"widgets"))

let test_execute_write_create_table_already_exists_raises () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"widgets" widgets_expected_schema;
  Alcotest.check_raises "table already exists raises Failure with DDL: prefix"
    (Failure "DDL: create table \"widgets\": table already exists") (fun () ->
      Storage.Engine.with_write_transaction environment (fun transaction ->
          let _result =
            Ddl_executor.execute_write environment transaction
              widgets_create_statement
          in
          ()))

let test_execute_write_create_table_rollback_on_raise () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  seed_table environment ~table_name:"widgets" widgets_expected_schema;
  (try
     Storage.Engine.with_write_transaction environment (fun transaction ->
         let _result =
           Ddl_executor.execute_write environment transaction
             widgets_create_statement
         in
         ())
   with Failure _ -> ());
  (* The aborted transaction must leave the pre-call state intact: the
     seeded schema is still bound, the seeded row is still readable. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "seeded schema preserved" (Some widgets_expected_schema)
        (Storage.Catalog.get environment transaction ~table_name:"widgets");
      match
        Storage.Engine.open_map environment transaction
          ~name:(Storage.Catalog.table_subdb_name "widgets")
      with
      | None ->
          Alcotest.fail
            "seeded storage subDB should still exist after aborted create"
      | Some map ->
          Alcotest.(check (option string))
            "seeded row preserved" (Some "any-value")
            (Storage.Engine.get map transaction ~key:"any-key"))

let () =
  Alcotest.run "ddl_executor"
    [
      ( "execute_read",
        [
          Alcotest.test_case "List_tables returns byte-sorted names" `Quick
            test_execute_read_list_tables_returns_byte_sorted_names;
          Alcotest.test_case "List_tables on empty catalog returns []" `Quick
            test_execute_read_list_tables_on_empty_catalog;
          Alcotest.test_case "Describe returns the stored schema" `Quick
            test_execute_read_describe_returns_stored_schema;
          Alcotest.test_case "Describe on a missing table raises Failure" `Quick
            test_execute_read_describe_no_such_table_raises;
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
          Alcotest.test_case
            "Create_table writes the catalog entry and storage subDB" `Quick
            test_execute_write_create_table_writes_catalog_and_storage;
          Alcotest.test_case
            "Create_table sets the qualifier on every catalog field" `Quick
            test_execute_write_create_table_qualifier_per_field;
          Alcotest.test_case "Create_table on an existing table raises Failure"
            `Quick test_execute_write_create_table_already_exists_raises;
          Alcotest.test_case
            "Create_table that raises rolls back catalog and storage" `Quick
            test_execute_write_create_table_rollback_on_raise;
        ] );
    ]
