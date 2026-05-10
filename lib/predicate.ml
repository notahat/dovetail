type op = Equal | NotEqual
type t = Compare of { column_name : string; op : op; literal : Value.t }

(* The static kind that classifies a runtime value. Used to type-check a
   predicate's literal against the column's declared kind. *)
let kind_of_value = function
  | Value.Int64 _ -> Value.Kind.Int64
  | Value.String _ -> Value.Kind.String
  | Value.Bool _ -> Value.Kind.Bool

(* Render a [Value.Kind.t] for inclusion in error messages. *)
let kind_name = function
  | Value.Kind.Int64 -> "Int64"
  | Value.Kind.String -> "String"
  | Value.Kind.Bool -> "Bool"

let resolve schema (Compare { column_name; op; literal }) =
  let column_position, field =
    match Schema.find_field schema column_name with
    | Some result -> result
    | None ->
        failwith
          (Printf.sprintf "Predicate.resolve: unknown column %S" column_name)
  in
  let literal_kind = kind_of_value literal in
  if field.kind <> literal_kind then
    failwith
      (Printf.sprintf
         "Predicate.resolve: type mismatch: column %S is %s, literal is %s"
         column_name (kind_name field.kind) (kind_name literal_kind));
  let comparator = match op with Equal -> ( = ) | NotEqual -> ( <> ) in
  fun (tuple : Schema.tuple) -> comparator tuple.(column_position) literal
