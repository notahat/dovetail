(** Tests for [Catalog]. *)

open Dovetail
open Test_helpers

let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    primary_key = [ "id" ];
  }

let orders_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "total"; kind = Int64; qualifier = Some "orders" };
      ];
    primary_key = [ "id" ];
  }

let schema_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<schema>")) ( = )

let test_round_trip () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema);
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "users round-trips" (Some users_schema)
        (Catalog.get environment transaction ~table_name:"users"))

let test_missing_table_returns_none () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema);
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "absent table" None
        (Catalog.get environment transaction ~table_name:"orders"))

let test_missing_catalog_returns_none () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. *)
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "no catalog yet" None
        (Catalog.get environment transaction ~table_name:"users"))

let test_multiple_schemas_dont_collide () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema;
      Catalog.put environment transaction ~table_name:"orders" orders_schema);
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option schema_testable))
        "users" (Some users_schema)
        (Catalog.get environment transaction ~table_name:"users");
      Alcotest.(check (option schema_testable))
        "orders" (Some orders_schema)
        (Catalog.get environment transaction ~table_name:"orders"))

let test_list_table_names_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.with_write_transaction environment (fun transaction ->
      Catalog.put environment transaction ~table_name:"users" users_schema;
      Catalog.put environment transaction ~table_name:"orders" orders_schema);
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (list string))
        "byte-sorted table names" [ "orders"; "users" ]
        (Catalog.list_table_names environment transaction))

let test_list_table_names_empty_catalog () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. *)
  Storage.with_read_transaction environment (fun transaction ->
      Alcotest.(check (list string))
        "no catalog yet returns empty list" []
        (Catalog.list_table_names environment transaction))

let () =
  Alcotest.run "catalog"
    [
      ( "round-trip",
        [
          Alcotest.test_case "put then get" `Quick test_round_trip;
          Alcotest.test_case "missing table returns None" `Quick
            test_missing_table_returns_none;
          Alcotest.test_case "missing catalog map returns None" `Quick
            test_missing_catalog_returns_none;
          Alcotest.test_case "multiple schemas do not collide" `Quick
            test_multiple_schemas_dont_collide;
        ] );
      ( "list_table_names",
        [
          Alcotest.test_case "returns byte-sorted table names" `Quick
            test_list_table_names_returns_byte_sorted_names;
          Alcotest.test_case "returns empty list when catalog absent" `Quick
            test_list_table_names_empty_catalog;
        ] );
    ]
