module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

type t = Row.column_reference list

(* Look up [reference] in [input_row_kind] and return its (position, field).
   Pre: [Plan.Typecheck] has validated [reference] -- the lookup never
   reaches the [Error] arm. *)
let resolve_column input_row_kind reference =
  match Row.find_field input_row_kind reference with
  | Ok result -> result
  | Error _ -> assert false

let format formatter columns =
  let rendered =
    columns |> List.map Row.format_column_reference |> String.concat ", "
  in
  Format.pp_print_string formatter rendered

let resolve (input_kind : Relation.kind) columns =
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
  let project_row (row : Row.value) : Row.value =
    Array.map (fun position -> row.(position)) positions
  in
  (projected_kind, project_row)
