type t = string list

(* Look up [column_name] in [input_schema] and return its (position, field).
   Raises [Failure] naming the missing column if it is not present. *)
let resolve_column input_schema column_name =
  match Schema.find_field input_schema column_name with
  | Some result -> result
  | None ->
      failwith
        (Printf.sprintf "Projection.resolve: unknown column %S" column_name)

(* Walk [columns] left to right, raising if the same name appears twice. *)
let check_no_duplicates columns =
  let seen = Hashtbl.create (List.length columns) in
  List.iter
    (fun column_name ->
      if Hashtbl.mem seen column_name then
        failwith
          (Printf.sprintf "Projection.resolve: duplicate column %S" column_name);
      Hashtbl.add seen column_name ())
    columns

let resolve input_schema columns =
  check_no_duplicates columns;
  let resolved =
    List.map
      (fun column_name -> resolve_column input_schema column_name)
      columns
  in
  let projected_fields = List.map (fun (_position, field) -> field) resolved in
  let positions = Array.of_list (List.map fst resolved) in
  let projected_schema : Schema.t =
    { fields = projected_fields; primary_key = [] }
  in
  let project_tuple (tuple : Schema.tuple) : Schema.tuple =
    Array.map (fun position -> tuple.(position)) positions
  in
  (projected_schema, project_tuple)
