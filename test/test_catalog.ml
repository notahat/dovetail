(** Tests for [Catalog]. *)

open Dovetail
open Test_helpers

let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64 };
        { name = "name"; kind = String };
        { name = "email"; kind = String };
        { name = "active"; kind = Bool };
      ];
    primary_key = [ "id" ];
  }

let orders_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64 };
        { name = "user_id"; kind = Int64 };
        { name = "total"; kind = Int64 };
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
    ]
