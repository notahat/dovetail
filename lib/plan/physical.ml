module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation

type t =
  | Catalog_source
  | Create_table_empty of { table_name : string; kind : Relation.kind }
  | Create_table_seeded of { table_name : string; source : t }
  | CrossProduct of { left : t; right : t }
  | Drop_table of { table_name : string }
  | Filter of { input : t; predicate : Expression.t }
  | FullScan of { table : string }
  | IndexedNestedLoopJoin of {
      outer : t;
      inner_table : string;
      outer_key_column : Row.column_reference;
      inner_position : [ `Left | `Right ];
    }
  | IndexLookup of { table : string; key : int64 }
  | Insert of { table : string; source : t }
  | NestedLoopJoin of { left : t; right : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | Relation_literal of { kind : Relation.kind; rows : Scalar.value list list }
  | Row_literal of { fields : (Row.column_reference * Scalar.value) list }
  | Scalar_literal of Scalar.value
  | Tables of { input : t }
  | Type_op of { input : t }
  | Unqualify of { input : t }

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
  | Catalog_source -> Format.fprintf formatter "%sCatalogSource@\n" prefix
  | Create_table_empty { table_name; kind } ->
      let columns =
        List.map (fun (field : Row.field) -> field.name) kind.row_kind
      in
      Format.fprintf formatter "%sCreateTableEmpty(%s, columns=%s)@\n" prefix
        table_name
        (String.concat ", " columns)
  | Create_table_seeded { table_name; source } ->
      Format.fprintf formatter "%sCreateTableSeeded(%s)@\n" prefix table_name;
      format_at formatter (indent + 1) source
  | CrossProduct { left; right } ->
      Format.fprintf formatter "%sCrossProduct@\n" prefix;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | Drop_table { table_name } ->
      Format.fprintf formatter "%sDropTable(%s)@\n" prefix table_name
  | Filter { input; predicate } ->
      Format.fprintf formatter "%sFilter(%a)@\n" prefix Expression.format
        predicate;
      format_at formatter (indent + 1) input
  | FullScan { table } ->
      Format.fprintf formatter "%sFullScan(%s)@\n" prefix table
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
  | IndexLookup { table; key } ->
      Format.fprintf formatter "%sIndexLookup(%s, key=%Ld)@\n" prefix table key
  | Insert { table; source } ->
      Format.fprintf formatter "%sInsert(%s)@\n" prefix table;
      format_at formatter (indent + 1) source
  | NestedLoopJoin { left; right; predicate } ->
      Format.fprintf formatter "%sNestedLoopJoin(%a)@\n" prefix
        Expression.format predicate;
      format_at formatter (indent + 1) left;
      format_at formatter (indent + 1) right
  | Project { input; columns } ->
      Format.fprintf formatter "%sProject(%a)@\n" prefix Projection.format
        columns;
      format_at formatter (indent + 1) input
  | Relation_literal { kind; rows } ->
      let columns =
        List.map (fun (field : Row.field) -> field.name) kind.row_kind
      in
      Format.fprintf formatter "%sRelationLiteral(columns=%s, rows=%d)@\n"
        prefix
        (String.concat ", " columns)
        (List.length rows)
  | Row_literal { fields } ->
      let format_field formatter (reference, value) =
        Format.fprintf formatter "%s=%a"
          (Row.format_column_reference reference)
          Scalar.format value
      in
      let separator formatter () = Format.pp_print_string formatter ", " in
      Format.fprintf formatter "%sRowLiteral(%a)@\n" prefix
        (Format.pp_print_list ~pp_sep:separator format_field)
        fields
  | Scalar_literal value ->
      Format.fprintf formatter "%sScalarLiteral(%a)@\n" prefix Scalar.format
        value
  | Tables { input } ->
      Format.fprintf formatter "%sTables@\n" prefix;
      format_at formatter (indent + 1) input
  | Type_op { input } ->
      Format.fprintf formatter "%sType@\n" prefix;
      format_at formatter (indent + 1) input
  | Unqualify { input } ->
      Format.fprintf formatter "%sUnqualify@\n" prefix;
      format_at formatter (indent + 1) input

let format formatter plan = format_at formatter 0 plan

(* The static result kind of an [Insert]: a one-column
   [insert_count : int64] row. Mirrors the runtime value [Eval_insert.evaluate]
   produces. *)
let insert_result_kind : Relation.kind =
  {
    row_kind =
      [ { name = "insert_count"; kind = Scalar.Int64; qualifier = None } ];
    refinements = [];
  }

(* The static result kind of [Create_table_empty] and
   [Create_table_seeded]: a one-column [created : string] row carrying the
   newly-created table's name. Mirrors the runtime value the evaluator
   produces. *)
let create_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "created"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

(* The static result kind of [Drop_table]: a one-column [dropped : string]
   row carrying the just-dropped table's name. *)
let drop_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "dropped"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

(* The static result kind of [Tables]: a one-column [name : string] row, one
   per table in the input catalog. Kept deliberately minimal -- no qualifier
   and no primary-key refinement -- so the relation composes cleanly with
   downstream operators. *)
let tables_result_kind : Relation.kind =
  {
    row_kind = [ { name = "name"; kind = Scalar.String; qualifier = None } ];
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
  | Catalog_source ->
      (* The catalog rung's static shape is a [Catalog.kind], not a
         [Relation.kind] — the two faces are different types. The [Type_op]
         evaluator short-circuits a [Catalog_source] input directly and never
         delegates to [kind_of] for it, so this arm is unreachable from
         the evaluator. The explicit failure surfaces any future caller that
         asks for a relation kind it can't provide. *)
      assert false
  | Create_table_empty _ | Create_table_seeded _ -> create_table_result_kind
  | CrossProduct { left; right } | NestedLoopJoin { left; right; _ } ->
      concatenated_kind (kind_of ~catalog left).row_kind
        (kind_of ~catalog right).row_kind
  | Drop_table _ -> drop_table_result_kind
  | Filter { input; _ } -> kind_of ~catalog input
  | FullScan { table } | IndexLookup { table; _ } ->
      lookup_table_kind ~catalog table
  | IndexedNestedLoopJoin { outer; inner_table; inner_position; _ } -> (
      let outer_row_kind = (kind_of ~catalog outer).row_kind in
      let inner_row_kind = (lookup_table_kind ~catalog inner_table).row_kind in
      match inner_position with
      | `Left -> concatenated_kind inner_row_kind outer_row_kind
      | `Right -> concatenated_kind outer_row_kind inner_row_kind)
  | Insert _ -> insert_result_kind
  | Project { input; columns } ->
      let projected_kind, _project_row =
        Projection.resolve (kind_of ~catalog input) columns
      in
      projected_kind
  | Relation_literal { kind; rows = _ } -> kind
  | Row_literal _ ->
      (* [Row_literal]'s evaluation result is a row value, not a relation.
         The [Type_op] evaluator catches a [Row_literal] input before
         delegating to [kind_of], so this arm is unreachable from the
         evaluator today; the explicit failure surfaces any future caller
         that asks for a relation kind it can't provide. *)
      failwith "Physical.kind_of: Row_literal does not produce a relation kind"
  | Scalar_literal _ ->
      (* [Scalar_literal]'s evaluation result is a scalar value, not a
         relation. The [Type_op] evaluator catches a [Scalar_literal] input
         before delegating to [kind_of], so this arm is unreachable from
         the evaluator today; the explicit failure surfaces any future
         caller that asks for a relation kind it can't provide. *)
      failwith
        "Physical.kind_of: Scalar_literal does not produce a relation kind"
  | Tables _ -> tables_result_kind
  | Type_op _ ->
      (* [Type_op]'s evaluation result is a relation kind, not a relation
         value, so it has no [Relation.kind] of its own. The [Eval] layer
         calls [kind_of] on the input of a [Type_op], never on the
         [Type_op] node itself. *)
      failwith "Physical.kind_of: Type_op does not produce a relation kind"
  | Unqualify { input } -> (
      let input_kind = kind_of ~catalog input in
      match Row.unqualify_kind input_kind.row_kind with
      | Ok row_kind -> { row_kind; refinements = input_kind.refinements }
      | Error detail ->
          failwith (Printf.sprintf "Physical.kind_of: unqualify: %s" detail))
