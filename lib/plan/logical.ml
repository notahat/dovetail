module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression

type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }

type mutation = Insert of { table : string; source : t }
type plan = Query of t | Mutation of mutation

let classify = function Query _ -> `Read | Mutation _ -> `Write

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

let format formatter plan = format_at formatter 0 plan

let format_mutation_at formatter indent (Insert { table; source }) =
  let prefix = String.make (indent * 2) ' ' in
  Format.fprintf formatter "%sInsert(%s)@\n" prefix table;
  format_at formatter (indent + 1) source

let format_plan formatter = function
  | Query plan -> format formatter plan
  | Mutation mutation -> format_mutation_at formatter 0 mutation
