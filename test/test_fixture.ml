(** Tests for [Fixture]. *)

open Dovetail
open Dovetail_core
open Test_helpers

let users_table_subdb_name = "table:users"
let orders_table_subdb_name = "table:orders"
let expected_users_field_names = [ "id"; "name"; "email"; "active" ]
let expected_orders_field_names = [ "id"; "user_id"; "description"; "amount" ]

(* The five users rows decomposed into (id, [name; email; active]) so tests
   can assert against the raw bytes after decoding. *)
let expected_users_decoded_rows : (int64 * Value.t list) list =
  [
    (1L, [ String "Alice"; String "alice@example.com"; Bool true ]);
    (2L, [ String "Bob"; String "bob@example.com"; Bool false ]);
    (3L, [ String "Carol"; String "carol@example.com"; Bool true ]);
    (4L, [ String "Dave"; String "dave@example.com"; Bool true ]);
    (5L, [ String "Eve"; String "eve@example.com"; Bool false ]);
  ]

(* The six orders rows decomposed into (id, [user_id; description; amount])
   for raw-bytes roundtrip assertions. *)
let expected_orders_decoded_rows : (int64 * Value.t list) list =
  [
    (1L, [ Int64 1L; String "Coffee"; Int64 5L ]);
    (2L, [ Int64 1L; String "Bagel"; Int64 4L ]);
    (3L, [ Int64 2L; String "Tea"; Int64 3L ]);
    (4L, [ Int64 3L; String "Sandwich"; Int64 8L ]);
    (5L, [ Int64 3L; String "Cake"; Int64 6L ]);
    (6L, [ Int64 5L; String "Cookie"; Int64 2L ]);
  ]

let test_populate_writes_users_schema () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      match Catalog.get environment transaction ~table_name:"users" with
      | None -> Alcotest.fail "expected users schema in catalog"
      | Some schema ->
          Alcotest.(check (list string))
            "field names" expected_users_field_names
            (List.map (fun (f : Schema.field) -> f.name) schema.fields);
          Alcotest.(check (list string))
            "primary key" [ "id" ] schema.primary_key)

let test_populate_writes_orders_schema () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      match Catalog.get environment transaction ~table_name:"orders" with
      | None -> Alcotest.fail "expected orders schema in catalog"
      | Some schema ->
          Alcotest.(check (list string))
            "field names" expected_orders_field_names
            (List.map (fun (f : Schema.field) -> f.name) schema.fields);
          Alcotest.(check (list string))
            "primary key" [ "id" ] schema.primary_key)

let test_populate_writes_five_users_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let users_map =
        match
          Storage.open_map environment transaction ~name:users_table_subdb_name
        with
        | Some map -> map
        | None -> Alcotest.fail "expected table:users subDB"
      in
      let pairs = Storage.with_iter_seq users_map transaction List.of_seq in
      Alcotest.(check int) "five rows" 5 (List.length pairs))

let test_populate_writes_six_orders_rows () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let orders_map =
        match
          Storage.open_map environment transaction ~name:orders_table_subdb_name
        with
        | Some map -> map
        | None -> Alcotest.fail "expected table:orders subDB"
      in
      let pairs = Storage.with_iter_seq orders_map transaction List.of_seq in
      Alcotest.(check int) "six rows" 6 (List.length pairs))

let test_populate_is_idempotent () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let users_map =
        Option.get
          (Storage.open_map environment transaction ~name:users_table_subdb_name)
      in
      let users_pairs =
        Storage.with_iter_seq users_map transaction List.of_seq
      in
      Alcotest.(check int) "still five users rows" 5 (List.length users_pairs);
      let orders_map =
        Option.get
          (Storage.open_map environment transaction
             ~name:orders_table_subdb_name)
      in
      let orders_pairs =
        Storage.with_iter_seq orders_map transaction List.of_seq
      in
      Alcotest.(check int) "still six orders rows" 6 (List.length orders_pairs))

let test_users_raw_bytes_decode_to_expected_tuples () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let users_map =
        Option.get
          (Storage.open_map environment transaction ~name:users_table_subdb_name)
      in
      let pairs = Storage.with_iter_seq users_map transaction List.of_seq in
      let decoded =
        List.map
          (fun (key_bytes, value_bytes) ->
            let id = Encoding.decode_int64_key key_bytes in
            let non_pk_values = Encoding.decode_tuple_value value_bytes in
            (id, non_pk_values))
          pairs
      in
      Alcotest.(check bool)
        "decoded rows match expected" true
        (decoded = expected_users_decoded_rows))

let test_orders_raw_bytes_decode_to_expected_tuples () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let orders_map =
        Option.get
          (Storage.open_map environment transaction
             ~name:orders_table_subdb_name)
      in
      let pairs = Storage.with_iter_seq orders_map transaction List.of_seq in
      let decoded =
        List.map
          (fun (key_bytes, value_bytes) ->
            let id = Encoding.decode_int64_key key_bytes in
            let non_pk_values = Encoding.decode_tuple_value value_bytes in
            (id, non_pk_values))
          pairs
      in
      Alcotest.(check bool)
        "decoded rows match expected" true
        (decoded = expected_orders_decoded_rows))

let () =
  Alcotest.run "fixture"
    [
      ( "populate",
        [
          Alcotest.test_case "writes the users schema" `Quick
            test_populate_writes_users_schema;
          Alcotest.test_case "writes the orders schema" `Quick
            test_populate_writes_orders_schema;
          Alcotest.test_case "writes the five users rows" `Quick
            test_populate_writes_five_users_rows;
          Alcotest.test_case "writes the six orders rows" `Quick
            test_populate_writes_six_orders_rows;
          Alcotest.test_case "is idempotent" `Quick test_populate_is_idempotent;
          Alcotest.test_case "users raw bytes decode to the expected tuples"
            `Quick test_users_raw_bytes_decode_to_expected_tuples;
          Alcotest.test_case "orders raw bytes decode to the expected tuples"
            `Quick test_orders_raw_bytes_decode_to_expected_tuples;
        ] );
    ]
