module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Expression = Dovetail_core.Expression

type t =
  | FullScan of { table : string }
  | Filter of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | IndexLookup of { table : string; key : int64 }
  | NestedLoopJoin of { left : t; right : t; predicate : Expression.t }
  | IndexedNestedLoopJoin of {
      outer : t;
      inner_table : string;
      outer_key_column : Row.column_reference;
      inner_position : [ `Left | `Right ];
    }
  | RelationLiteral of { columns : string list; rows : Scalar.value list list }
  | Insert of { table : string; source : t }

(* Pretty-print [plan] starting at [indent] levels of two-space indentation.
   Each operator emits one header line ([Op] or [Op(arg)]) and recurses into
   its inputs at one more level of indent. The recursion terminates at
   [FullScan] and [IndexLookup], the nullary operators.

   The 35-line guideline is treated as a deliberate exception here: this is
   one dispatch over the [Physical.t] constructors, where each arm is a
   single [fprintf] tailored to its operator's parameters. Splitting per
   operator would add trivial helpers without making any individual line
   clearer. Matches the precedent set by {!Parser.expression}. *)
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
      Format.fprintf formatter "%sProject(%a)@\n" prefix Projection.format
        columns;
      format_at formatter (indent + 1) input
  | CrossProduct { left; right } ->
      Format.fprintf formatter "%sCrossProduct@\n" prefix;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | IndexLookup { table; key } ->
      Format.fprintf formatter "%sIndexLookup(%s, key=%Ld)@\n" prefix table key
  | NestedLoopJoin { left; right; predicate } ->
      Format.fprintf formatter "%sNestedLoopJoin(%a)@\n" prefix
        Expression.format predicate;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | IndexedNestedLoopJoin
      { outer; inner_table; outer_key_column; inner_position } ->
      let inner_position_label =
        match inner_position with `Left -> "Left" | `Right -> "Right"
      in
      Format.fprintf formatter
        "%sIndexedNestedLoopJoin(inner=%s, outer_key=%s, inner_position=%s)@\n"
        prefix inner_table
        (Row.format_column_reference outer_key_column)
        inner_position_label;
      format_at formatter (indent + 1) outer
  | RelationLiteral { columns; rows } ->
      Format.fprintf formatter "%sRelationLiteral(columns=%s, rows=%d)@\n"
        prefix
        (String.concat ", " columns)
        (List.length rows)
  | Insert { table; source } ->
      Format.fprintf formatter "%sInsert(%s)@\n" prefix table;
      format_at formatter (indent + 1) source

let format formatter plan = format_at formatter 0 plan
