module Kind = struct
  type t = Int64 | String | Bool

  let to_string = function
    | Int64 -> "Int64"
    | String -> "String"
    | Bool -> "Bool"
end

type t = Int64 of int64 | String of string | Bool of bool
type kind = Kind.t = Int64 | String | Bool
type data = t = Int64 of int64 | String of string | Bool of bool

let kind_of = function
  | Int64 _ -> Kind.Int64
  | String _ -> Kind.String
  | Bool _ -> Kind.Bool

let format formatter = function
  | Int64 number -> Format.pp_print_string formatter (Int64.to_string number)
  | String text -> Format.fprintf formatter "\"%s\"" text
  | Bool true -> Format.pp_print_string formatter "true"
  | Bool false -> Format.pp_print_string formatter "false"

let to_string value = Format.asprintf "%a" format value
