type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | NestedLoopJoin of { left : t; right : t; predicate : Expression.t }

(* Render a [Projection.t] as a comma-separated list, each column in its
   source-like form (bare or [qualifier.name] dotted). *)
let render_columns columns =
  columns |> List.map Schema.format_column_reference |> String.concat ", "

(* Pretty-print [plan] starting at [indent] levels of two-space indentation.
   Each operator emits one header line ([Op] or [Op(arg)]) and recurses into
   its inputs at one more level of indent. The recursion terminates at
   [FullScan], the only nullary operator. *)
let rec format_at formatter indent plan =
  let prefix = String.make (indent * 2) ' ' in
  match plan with
  | FullScan { table } ->
      Format.fprintf formatter "%sFullScan(%s)@\n" prefix table
  | Filter { input; predicate } ->
      Format.fprintf formatter "%sFilter(%a)@\n" prefix Expression.format
        predicate;
      format_at formatter (indent + 1) input
  | Project { input; columns } ->
      Format.fprintf formatter "%sProject(%s)@\n" prefix
        (render_columns columns);
      format_at formatter (indent + 1) input
  | CrossProduct { left; right } ->
      Format.fprintf formatter "%sCrossProduct@\n" prefix;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | NestedLoopJoin { left; right; predicate } ->
      Format.fprintf formatter "%sNestedLoopJoin(%a)@\n" prefix
        Expression.format predicate;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right

let format formatter plan = format_at formatter 0 plan
