module Kind = struct
  type t = Int64 | String | Bool

  let to_string = function
    | Int64 -> "Int64"
    | String -> "String"
    | Bool -> "Bool"
end

type t = Int64 of int64 | String of string | Bool of bool

let kind_of = function
  | Int64 _ -> Kind.Int64
  | String _ -> Kind.String
  | Bool _ -> Kind.Bool
