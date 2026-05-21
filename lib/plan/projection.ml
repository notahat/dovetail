module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

type t = Row.column_reference list

(* Look up [reference] in [input_row_kind] and return its (position, field).
   Raises [Failure] with the [Projection.resolve:] prefix on unknown or
   ambiguous references. *)
let resolve_column input_row_kind reference =
  match Row.find_field input_row_kind reference with
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
        let key = Row.format_column_reference reference in
        if List.mem key seen then
          failwith
            (Printf.sprintf "Projection.resolve: duplicate column %S" key);
        walk (key :: seen) rest
  in
  walk [] columns

let format formatter columns =
  let rendered =
    columns |> List.map Row.format_column_reference |> String.concat ", "
  in
  Format.pp_print_string formatter rendered

let resolve (input_kind : Relation.kind) columns =
  check_no_duplicates columns;
  let resolved =
    List.map
      (fun reference -> resolve_column input_kind.row_kind reference)
      columns
  in
  let projected_row_kind =
    List.map (fun (_position, field) -> field) resolved
  in
  let positions = Array.of_list (List.map fst resolved) in
  let projected_kind : Relation.kind =
    { row_kind = projected_row_kind; refinements = [] }
  in
  let project_row (row : Row.data) : Row.data =
    Array.map (fun position -> row.(position)) positions
  in
  (projected_kind, project_row)
