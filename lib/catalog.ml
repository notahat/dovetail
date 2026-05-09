let map_name = "catalog"

let get environment transaction ~table_name =
  match Storage.open_map environment transaction ~name:map_name with
  | None -> None
  | Some map -> (
      match Storage.get map transaction ~key:table_name with
      | None -> None
      | Some bytes ->
          let schema : Schema.t = Marshal.from_string bytes 0 in
          Some schema)

let put environment transaction ~table_name schema =
  let map = Storage.create_map environment transaction ~name:map_name in
  let bytes = Marshal.to_string (schema : Schema.t) [] in
  Storage.put map transaction ~key:table_name ~value:bytes
