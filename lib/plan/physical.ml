module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Relation_literal = Dovetail_core.Relation_literal

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

(* The static result kind of an [Insert]: a one-column
   [insert_count : int64] row. Mirrors the runtime value [Eval.evaluate_insert]
   produces. *)
let insert_result_kind : Relation.kind =
  {
    row_kind =
      [ { name = "insert_count"; kind = Scalar.Int64; qualifier = None } ];
    refinements = [];
  }

(* Look up [table] in [catalog] or raise a user-readable [Failure]. *)
let lookup_table_kind ~catalog table =
  match catalog table with
  | Some kind -> kind
  | None -> failwith (Printf.sprintf "Physical.kind_of: unknown table %S" table)

(* Build a [Relation.kind] that concatenates two row kinds in order and
   carries no refinements. Joins and the cross product all use this shape:
   derived relations don't keep refinements from their inputs. *)
let concatenated_kind left_row_kind right_row_kind : Relation.kind =
  { row_kind = left_row_kind @ right_row_kind; refinements = [] }

let rec kind_of ~catalog (plan : t) : Relation.kind =
  match plan with
  | FullScan { table } | IndexLookup { table; _ } ->
      lookup_table_kind ~catalog table
  | Filter { input; _ } -> kind_of ~catalog input
  | Project { input; columns } ->
      let projected_kind, _project_row =
        Projection.resolve (kind_of ~catalog input) columns
      in
      projected_kind
  | CrossProduct { left; right } | NestedLoopJoin { left; right; _ } ->
      concatenated_kind (kind_of ~catalog left).row_kind
        (kind_of ~catalog right).row_kind
  | IndexedNestedLoopJoin { outer; inner_table; inner_position; _ } -> (
      let outer_row_kind = (kind_of ~catalog outer).row_kind in
      let inner_row_kind = (lookup_table_kind ~catalog inner_table).row_kind in
      match inner_position with
      | `Left -> concatenated_kind inner_row_kind outer_row_kind
      | `Right -> concatenated_kind outer_row_kind inner_row_kind)
  | RelationLiteral { columns; rows } ->
      let first_row =
        match rows with
        | first :: _ -> first
        | [] ->
            failwith
              "Physical.kind_of: relation literal must have at least one row"
      in
      Relation_literal.kind_of ~columns ~first_row
  | Insert _ -> insert_result_kind
