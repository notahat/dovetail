type field = Schema.field = {
  name : string;
  kind : Value.kind;
  qualifier : string option;
}

type kind = field list
type data = Value.data array

type column_reference = Schema.column_reference = {
  qualifier : string option;
  name : string;
}

let format_column_reference = Schema.format_column_reference
let format_field_name = Schema.format_field_name

let find_field (row_kind : kind) reference =
  Schema.find_field { fields = row_kind; primary_key = [] } reference
