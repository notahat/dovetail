type statement = List_tables | Drop_table of { table_name : string }
type read_result = Listed of string list
type write_result = Dropped of string

let classify = function List_tables -> `Read | Drop_table _ -> `Write

let execute_read environment transaction = function
  | List_tables -> Listed (Catalog.list_table_names environment transaction)
  | Drop_table _ ->
      (* Routing invariant: Drop_table is a write statement; the REPL
         must classify and route it to execute_write. *)
      assert false

let execute_write _environment _transaction = function
  | List_tables ->
      (* Routing invariant: List_tables is a read statement; the REPL
         must classify and route it to execute_read. *)
      assert false
  | Drop_table _ ->
      (* TODO(slice-12-step-5a): implement the catalog/storage drop. *)
      assert false
