let statement = function
  | Statement.List_tables -> ":list tables"
  | Statement.Drop_table { table_name } -> ":drop table " ^ table_name
