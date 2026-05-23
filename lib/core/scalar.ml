type kind = Int64 | String | Bool
type value = Int64 of int64 | String of string | Bool of bool

let kind_of : value -> kind = function
  | Int64 _ -> Int64
  | String _ -> String
  | Bool _ -> Bool

let kind_to_string : kind -> string = function
  | Int64 -> "Int64"
  | String -> "String"
  | Bool -> "Bool"

let format_kind formatter (kind : kind) =
  match kind with
  | Int64 -> Format.pp_print_string formatter "int64"
  | String -> Format.pp_print_string formatter "string"
  | Bool -> Format.pp_print_string formatter "bool"

let format formatter = function
  | Int64 number -> Format.pp_print_string formatter (Int64.to_string number)
  | String text -> Format.fprintf formatter "\"%s\"" text
  | Bool true -> Format.pp_print_string formatter "true"
  | Bool false -> Format.pp_print_string formatter "false"

let to_string value = Format.asprintf "%a" format value
