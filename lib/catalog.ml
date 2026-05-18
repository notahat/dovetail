module Schema = Dovetail_core.Schema

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

let list_table_names environment transaction =
  match Storage.open_map environment transaction ~name:map_name with
  | None -> []
  | Some map ->
      Storage.with_iter_seq map transaction (fun pairs ->
          pairs |> Seq.map (fun (key, _value) -> key) |> List.of_seq)

let delete environment transaction ~table_name =
  match Storage.open_map environment transaction ~name:map_name with
  | None -> ()
  | Some map -> Storage.delete map transaction ~key:table_name

let table_subdb_name table_name = "table:" ^ table_name
