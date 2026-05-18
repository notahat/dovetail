module Schema = Dovetail_core.Schema

type t = Schema.column_reference list

(* Look up [reference] in [input_schema] and return its (position, field).
   Raises [Failure] with the [Projection.resolve:] prefix on unknown or
   ambiguous references. *)
let resolve_column input_schema reference =
  match Schema.find_field input_schema reference with
  | Ok result -> result
  | Error message -> failwith ("Projection.resolve: " ^ message)

(* Walk [columns] left to right, raising if the same column reference (in its
   source form) appears twice. [List.mem] is O(n^2) overall, which is fine
   for projection sizes -- a handful of columns at most -- and lets the
   function stay pure-functional. *)
let check_no_duplicates columns =
  let rec walk seen = function
    | [] -> ()
    | reference :: rest ->
        let key = Schema.format_column_reference reference in
        if List.mem key seen then
          failwith
            (Printf.sprintf "Projection.resolve: duplicate column %S" key);
        walk (key :: seen) rest
  in
  walk [] columns

let format formatter columns =
  let rendered =
    columns |> List.map Schema.format_column_reference |> String.concat ", "
  in
  Format.pp_print_string formatter rendered

let resolve input_schema columns =
  check_no_duplicates columns;
  let resolved =
    List.map (fun reference -> resolve_column input_schema reference) columns
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
