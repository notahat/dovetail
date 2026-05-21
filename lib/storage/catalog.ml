module Relation = Dovetail_core.Relation

(* TODO(catalog-format): replace the Marshal round-trip with a hand-rolled
   encoding that does not depend on OCaml's runtime representation and that
   carries a version tag. See {!Catalog}'s mli for the consequences of the
   current choice. *)

let map_name = "catalog"

let get environment transaction ~table_name =
  match Engine.open_map environment transaction ~name:map_name with
  | None -> None
  | Some map -> (
      match Engine.get map transaction ~key:table_name with
      | None -> None
      | Some bytes ->
          let kind : Relation.kind = Marshal.from_string bytes 0 in
          Some kind)

let put environment transaction ~table_name kind =
  let map = Engine.create_map environment transaction ~name:map_name in
  let bytes = Marshal.to_string (kind : Relation.kind) [] in
  Engine.put map transaction ~key:table_name ~value:bytes

let list_table_names environment transaction =
  match Engine.open_map environment transaction ~name:map_name with
  | None -> []
  | Some map ->
      Engine.with_iter_seq map transaction (fun pairs ->
          pairs |> Seq.map (fun (key, _value) -> key) |> List.of_seq)

let delete environment transaction ~table_name =
  match Engine.open_map environment transaction ~name:map_name with
  | None -> ()
  | Some map -> Engine.delete map transaction ~key:table_name

let table_subdb_name table_name = "table:" ^ table_name
