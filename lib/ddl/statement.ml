type t = List_tables | Drop_table of { table_name : string }
type read_result = Listed of string list
type write_result = Dropped of string

let classify = function List_tables -> `Read | Drop_table _ -> `Write
