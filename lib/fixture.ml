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

let users_rows : Schema.tuple list =
  [
    [| Int64 1L; String "Alice"; String "alice@example.com"; Bool true |];
    [| Int64 2L; String "Bob"; String "bob@example.com"; Bool false |];
    [| Int64 3L; String "Carol"; String "carol@example.com"; Bool true |];
    [| Int64 4L; String "Dave"; String "dave@example.com"; Bool true |];
    [| Int64 5L; String "Eve"; String "eve@example.com"; Bool false |];
  ]

let users_table_subdb_name = "table:users"

(* Decompose a users row into (key_bytes, value_bytes). The shape is fixed
   for slice 1: PK is the single int64 [id] column, non-PK is [name; email;
   active]. *)
let encode_users_row = function
  | [| Value.Int64 id; name; email; active |] ->
      let key = Encoding.encode_int64_key id in
      let value = Encoding.encode_tuple_value [ name; email; active ] in
      (key, value)
  | _ -> assert false

let populate_if_empty environment =
  Storage.with_write_transaction environment (fun transaction ->
      match Catalog.get environment transaction ~table_name:"users" with
      | Some _ -> ()
      | None ->
          Catalog.put environment transaction ~table_name:"users" users_schema;
          let users_map =
            Storage.create_map environment transaction
              ~name:users_table_subdb_name
          in
          List.iter
            (fun row ->
              let key, value = encode_users_row row in
              Storage.put users_map transaction ~key ~value)
            users_rows)
