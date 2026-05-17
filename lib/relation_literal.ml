let schema_of ~columns ~first_row =
  let column_count = List.length columns in
  let value_count = List.length first_row in
  if value_count <> column_count then
    invalid_arg
      (Printf.sprintf
         "Relation_literal.schema_of: row has %d value(s) but %d column(s) \
          declared"
         value_count column_count);
  let fields =
    List.map2
      (fun column_name row_value : Schema.field ->
        { name = column_name; kind = Value.kind_of row_value; qualifier = None })
      columns first_row
  in
  ({ fields; primary_key = [] } : Schema.t)
