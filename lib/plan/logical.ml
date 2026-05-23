module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression

type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
  | Insert of { table : string; source : t }

(* Walks a plan and reports the strongest transaction access any operator
   in it needs. Insert is the only write operator today; every other
   operator threads its inputs' access through unchanged. The walker is
   the seam where future write-capable operators declare their access
   locally, without callers needing to enumerate them. *)
let rec required_access = function
  | Scan _ -> `Read
  | Restrict { input; _ } -> required_access input
  | Project { input; _ } -> required_access input
  | CrossProduct { left; right } ->
      access_max (required_access left) (required_access right)
  | RelationLiteral _ -> `Read
  | Insert { source; _ } -> access_max `Write (required_access source)

and access_max left right =
  match (left, right) with `Write, _ | _, `Write -> `Write | _ -> `Read

(* Pretty-print [plan] starting at [indent] levels of two-space indentation.
   Mirrors [Physical.format_at]: one header line per operator, inputs
   indented one level deeper, [Scan] as the only nullary leaf. The 35-line
   guideline is treated as the same deliberate exception it is in
   [Physical.format_at] -- one dispatch over the constructors, each arm a
   single [fprintf] tailored to its operator's parameters. *)
let rec format_at formatter indent plan =
  let prefix = String.make (indent * 2) ' ' in
  match plan with
  | Scan { table } -> Format.fprintf formatter "%sScan(%s)@\n" prefix table
  | Restrict { input; predicate } ->
      Format.fprintf formatter "%sRestrict(%a)@\n" prefix Expression.format
        predicate;
      format_at formatter (indent + 1) input
  | Project { input; columns } ->
      Format.fprintf formatter "%sProject(%a)@\n" prefix Projection.format
        columns;
      format_at formatter (indent + 1) input
  | CrossProduct { left; right } ->
      Format.fprintf formatter "%sCrossProduct@\n" prefix;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | RelationLiteral { columns; rows } ->
      Format.fprintf formatter "%sRelationLiteral(columns=%s, rows=%d)@\n"
        prefix
        (String.concat ", " columns)
        (List.length rows)
  | Insert { table; source } ->
      Format.fprintf formatter "%sInsert(%s)@\n" prefix table;
      format_at formatter (indent + 1) source

let format formatter plan = format_at formatter 0 plan
