(** Tests for [Catalog]. *)

open Test_helpers
module Storage = Dovetail_storage
module Catalog = Dovetail_core.Catalog

let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "total"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let kind_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<kind>")) ( = )

let catalog_kind_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<catalog kind>")) ( = )

let test_round_trip () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "users round-trips" (Some users_kind)
        (Storage.Catalog.get environment transaction ~table_name:"users"))

let test_missing_table_returns_none () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "absent table" None
        (Storage.Catalog.get environment transaction ~table_name:"orders"))

let test_missing_catalog_returns_none () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "no catalog yet" None
        (Storage.Catalog.get environment transaction ~table_name:"users"))

let test_multiple_kinds_dont_collide () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      Storage.Catalog.put environment transaction ~table_name:"orders"
        orders_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "users" (Some users_kind)
        (Storage.Catalog.get environment transaction ~table_name:"users");
      Alcotest.(check (option kind_testable))
        "orders" (Some orders_kind)
        (Storage.Catalog.get environment transaction ~table_name:"orders"))

let test_delete_removes_table_entry () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      Storage.Catalog.delete environment transaction ~table_name:"users");
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "users gone after delete" None
        (Storage.Catalog.get environment transaction ~table_name:"users"))

let test_delete_is_no_op_on_absent_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      (* Deleting a never-bound table must not raise and must leave
         sibling bindings untouched. *)
      Storage.Catalog.delete environment transaction ~table_name:"never-there");
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (option kind_testable))
        "sibling binding untouched" (Some users_kind)
        (Storage.Catalog.get environment transaction ~table_name:"users"))

let test_delete_on_fresh_environment_is_no_op () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. Delete must
     tolerate this without raising. *)
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.delete environment transaction ~table_name:"users")

let test_list_table_names_returns_byte_sorted_names () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      Storage.Catalog.put environment transaction ~table_name:"orders"
        orders_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (list string))
        "byte-sorted table names" [ "orders"; "users" ]
        (Storage.Catalog.list_table_names environment transaction))

let test_list_table_names_empty_catalog () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check (list string))
        "no catalog yet returns empty list" []
        (Storage.Catalog.list_table_names environment transaction))

let test_snapshot_kind_on_fresh_environment_is_empty () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  (* Fresh environment -- catalog subDB has never been created. *)
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check catalog_kind_testable)
        "fresh environment snapshots empty"
        ({ relation_kinds = [] } : Catalog.kind)
        (Storage.Catalog.snapshot_kind environment transaction))

let test_snapshot_kind_single_table () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check catalog_kind_testable)
        "single-table snapshot"
        ({ relation_kinds = [ ("users", users_kind) ] } : Catalog.kind)
        (Storage.Catalog.snapshot_kind environment transaction))

let test_snapshot_kind_multi_table_byte_sorted () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Storage.Engine.with_write_transaction environment (fun transaction ->
      Storage.Catalog.put environment transaction ~table_name:"users" users_kind;
      Storage.Catalog.put environment transaction ~table_name:"orders"
        orders_kind);
  Storage.Engine.with_read_transaction environment (fun transaction ->
      Alcotest.(check catalog_kind_testable)
        "multi-table snapshot is byte-sorted"
        ({ relation_kinds = [ ("orders", orders_kind); ("users", users_kind) ] }
          : Catalog.kind)
        (Storage.Catalog.snapshot_kind environment transaction))

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
          Alcotest.test_case "multiple kinds do not collide" `Quick
            test_multiple_kinds_dont_collide;
        ] );
      ( "list_table_names",
        [
          Alcotest.test_case "returns byte-sorted table names" `Quick
            test_list_table_names_returns_byte_sorted_names;
          Alcotest.test_case "returns empty list when catalog absent" `Quick
            test_list_table_names_empty_catalog;
        ] );
      ( "snapshot_kind",
        [
          Alcotest.test_case "fresh environment returns empty kind" `Quick
            test_snapshot_kind_on_fresh_environment_is_empty;
          Alcotest.test_case "single table" `Quick
            test_snapshot_kind_single_table;
          Alcotest.test_case "multi-table snapshot is byte-sorted" `Quick
            test_snapshot_kind_multi_table_byte_sorted;
        ] );
      ( "delete",
        [
          Alcotest.test_case "delete removes the table entry" `Quick
            test_delete_removes_table_entry;
          Alcotest.test_case "delete on an absent table is a no-op" `Quick
            test_delete_is_no_op_on_absent_table;
          Alcotest.test_case "delete on a fresh environment is a no-op" `Quick
            test_delete_on_fresh_environment_is_no_op;
        ] );
    ]
