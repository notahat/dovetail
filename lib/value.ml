module Kind = struct
  type t = Int64 | String | Bool
end

type t = Int64 of int64 | String of string | Bool of bool
