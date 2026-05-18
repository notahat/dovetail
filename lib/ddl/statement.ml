module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema

type field = { name : string; kind : Value.Kind.t }

type t =
  | List_tables
  | Drop_table of { table_name : string }
  | Describe of { table_name : string }
  | Create_table of {
      table_name : string;
      fields : field list;
      primary_key : string list;
    }

type read_result =
  | Listed of string list
  | Described of { table_name : string; schema : Schema.t }

type write_result = Dropped of string | Created of string

let classify = function
  | List_tables | Describe _ -> `Read
  | Drop_table _ | Create_table _ -> `Write

(* Adapt a stored [Schema.t] into a [Create_table]-shaped statement: drop
   the per-field qualifiers (the DDL surface has no notion of qualified
   columns) and preserve field order and primary-key order verbatim. The
   round-trip with the catalog's storage shape -- where every field's
   qualifier is [Some table_name] -- is restored by the [Create_table]
   executor when it reconstructs the [Schema.t]. *)
let of_schema ~table_name (schema : Schema.t) : t =
  let fields =
    List.map
      (fun (field : Schema.field) : field ->
        { name = field.name; kind = field.kind })
      schema.fields
  in
  Create_table { table_name; fields; primary_key = schema.primary_key }
