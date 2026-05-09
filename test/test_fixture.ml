(** Tests for [Fixture]. *)

open Dovetail
open Test_helpers

let users_table_subdb_name = "table:users"
let expected_field_names = [ "id"; "name"; "email"; "active" ]

(* The five users rows decomposed into (id, [name; email; active]) so tests
   can assert against the raw bytes after decoding. *)
let expected_rows : (int64 * Value.t list) list =
  [
    (1L, [ String "Alice"; String "alice@example.com"; Bool true ]);
    (2L, [ String "Bob"; String "bob@example.com"; Bool false ]);
    (3L, [ String "Carol"; String "carol@example.com"; Bool true ]);
    (4L, [ String "Dave"; String "dave@example.com"; Bool true ]);
    (5L, [ String "Eve"; String "eve@example.com"; Bool false ]);
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
            "field names" expected_field_names
            (List.map (fun (f : Schema.field) -> f.name) schema.fields);
          Alcotest.(check (list string))
            "primary key" [ "id" ] schema.primary_key)

let test_populate_writes_five_rows () =
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
      let pairs = Storage.iter_seq users_map transaction |> List.of_seq in
      Alcotest.(check int) "five rows" 5 (List.length pairs))

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
      let pairs = Storage.iter_seq users_map transaction |> List.of_seq in
      Alcotest.(check int) "still five rows" 5 (List.length pairs))

let test_raw_bytes_decode_to_expected_tuples () =
  with_temp_dir @@ fun dir ->
  with_environment dir @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let users_map =
        Option.get
          (Storage.open_map environment transaction ~name:users_table_subdb_name)
      in
      let pairs = Storage.iter_seq users_map transaction |> List.of_seq in
      let decoded =
        List.map
          (fun (key_bytes, value_bytes) ->
            let id = Encoding.decode_int64_key key_bytes in
            let non_pk_values = Encoding.decode_tuple_value value_bytes in
            (id, non_pk_values))
          pairs
      in
      Alcotest.(check bool)
        "decoded rows match expected" true (decoded = expected_rows))

let () =
  Alcotest.run "fixture"
    [
      ( "populate",
        [
          Alcotest.test_case "writes the users schema" `Quick
            test_populate_writes_users_schema;
          Alcotest.test_case "writes the five rows" `Quick
            test_populate_writes_five_rows;
          Alcotest.test_case "is idempotent" `Quick test_populate_is_idempotent;
          Alcotest.test_case "raw bytes decode to the expected tuples" `Quick
            test_raw_bytes_decode_to_expected_tuples;
        ] );
    ]
