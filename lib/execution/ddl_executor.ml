module Ddl = Dovetail_ddl
module Storage = Dovetail_storage

let execute_read environment transaction :
    Ddl.Statement.t -> Ddl.Statement.read_result = function
  | List_tables ->
      Listed (Storage.Catalog.list_table_names environment transaction)
