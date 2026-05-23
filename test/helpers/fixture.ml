module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Storage = Dovetail_storage

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

let users_rows : Row.value list =
  [
    [| Int64 1L; String "Alice"; String "alice@example.com"; Bool true |];
    [| Int64 2L; String "Bob"; String "bob@example.com"; Bool false |];
    [| Int64 3L; String "Carol"; String "carol@example.com"; Bool true |];
    [| Int64 4L; String "Dave"; String "dave@example.com"; Bool true |];
    [| Int64 5L; String "Eve"; String "eve@example.com"; Bool false |];
  ]

let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

let orders_rows : Row.value list =
  [
    [| Int64 1L; Int64 1L; String "Coffee"; Int64 5L |];
    [| Int64 2L; Int64 1L; String "Bagel"; Int64 4L |];
    [| Int64 3L; Int64 2L; String "Tea"; Int64 3L |];
    [| Int64 4L; Int64 3L; String "Sandwich"; Int64 8L |];
    [| Int64 5L; Int64 3L; String "Cake"; Int64 6L |];
    [| Int64 6L; Int64 5L; String "Cookie"; Int64 2L |];
  ]

(* Write [kind] to the catalog and [rows] to a fresh storage subDB for
   [table_name], if [table_name] is not already present in the catalog.
   The subDB's name comes from {!Storage.Catalog.table_subdb_name}, the single
   source of truth for the [table:] namespace convention. *)
let populate_table environment transaction ~table_name ~kind ~rows =
  match Storage.Catalog.get environment transaction ~table_name with
  | Some _ -> ()
  | None ->
      Storage.Catalog.put environment transaction ~table_name kind;
      let table_map =
        Storage.Engine.create_map environment transaction
          ~name:(Storage.Catalog.table_subdb_name table_name)
      in
      List.iter
        (fun row ->
          let key, value = Storage.Row_codec.encode_row kind row in
          Storage.Engine.put table_map transaction ~key ~value)
        rows

let populate_if_empty environment =
  Storage.Engine.with_write_transaction environment (fun transaction ->
      populate_table environment transaction ~table_name:"users"
        ~kind:users_kind ~rows:users_rows;
      populate_table environment transaction ~table_name:"orders"
        ~kind:orders_kind ~rows:orders_rows)
