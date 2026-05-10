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

let orders_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64 };
        { name = "user_id"; kind = Int64 };
        { name = "description"; kind = String };
        { name = "amount"; kind = Int64 };
      ];
    primary_key = [ "id" ];
  }

let orders_rows : Schema.tuple list =
  [
    [| Int64 1L; Int64 1L; String "Coffee"; Int64 5L |];
    [| Int64 2L; Int64 1L; String "Bagel"; Int64 4L |];
    [| Int64 3L; Int64 2L; String "Tea"; Int64 3L |];
    [| Int64 4L; Int64 3L; String "Sandwich"; Int64 8L |];
    [| Int64 5L; Int64 3L; String "Cake"; Int64 6L |];
    [| Int64 6L; Int64 5L; String "Cookie"; Int64 2L |];
  ]

let users_table_subdb_name = "table:users"
let orders_table_subdb_name = "table:orders"

(* Decompose a users row into (key_bytes, value_bytes). The shape is fixed
   for slice 1: PK is the single int64 [id] column, non-PK is [name; email;
   active]. *)
let encode_users_row = function
  | [| Value.Int64 id; name; email; active |] ->
      let key = Encoding.encode_int64_key id in
      let value = Encoding.encode_tuple_value [ name; email; active ] in
      (key, value)
  | _ -> assert false

(* Decompose an orders row into (key_bytes, value_bytes). PK is the single
   int64 [id] column, non-PK is [user_id; description; amount]. *)
let encode_orders_row = function
  | [| Value.Int64 id; user_id; description; amount |] ->
      let key = Encoding.encode_int64_key id in
      let value =
        Encoding.encode_tuple_value [ user_id; description; amount ]
      in
      (key, value)
  | _ -> assert false

(* Write [schema] to the catalog and [rows] to a fresh subDB named
   [subdb_name], if [table_name] is not already present in the catalog. *)
let populate_table environment transaction ~table_name ~subdb_name ~schema ~rows
    ~encode_row =
  match Catalog.get environment transaction ~table_name with
  | Some _ -> ()
  | None ->
      Catalog.put environment transaction ~table_name schema;
      let table_map =
        Storage.create_map environment transaction ~name:subdb_name
      in
      List.iter
        (fun row ->
          let key, value = encode_row row in
          Storage.put table_map transaction ~key ~value)
        rows

let populate_if_empty environment =
  Storage.with_write_transaction environment (fun transaction ->
      populate_table environment transaction ~table_name:"users"
        ~subdb_name:users_table_subdb_name ~schema:users_schema ~rows:users_rows
        ~encode_row:encode_users_row;
      populate_table environment transaction ~table_name:"orders"
        ~subdb_name:orders_table_subdb_name ~schema:orders_schema
        ~rows:orders_rows ~encode_row:encode_orders_row)
