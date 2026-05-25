module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

type t =
  | Scan of { table : string }
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : Projection.t }
  | CrossProduct of { left : t; right : t }
  | Relation_literal of { kind : Relation.kind; rows : Scalar.value list list }
  | Insert of { table : string; source : t }
  | Unqualify of { input : t }
  | Type_op of { input : t }
  | Scalar_literal of Scalar.value
  | Drop_table of { table_name : string }
  | Create_table_empty of { table_name : string; kind : Relation.kind }
  | Create_table_seeded of { table_name : string; source : t }
  | Row_literal of { fields : (Row.column_reference * Scalar.value) list }
  | Catalog_source

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
  | Relation_literal _ -> `Read
  | Insert { source; _ } -> access_max `Write (required_access source)
  | Unqualify { input } -> required_access input
  | Type_op { input } -> required_access input
  | Scalar_literal _ -> `Read
  | Row_literal _ -> `Read
  | Drop_table _ -> `Write
  | Create_table_empty _ -> `Write
  | Create_table_seeded { source; _ } ->
      access_max `Write (required_access source)
  | Catalog_source -> `Read

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
  | Relation_literal { kind; rows } ->
      let columns =
        List.map (fun (field : Row.field) -> field.name) kind.row_kind
      in
      Format.fprintf formatter "%sRelationLiteral(columns=%s, rows=%d)@\n"
        prefix
        (String.concat ", " columns)
        (List.length rows)
  | Insert { table; source } ->
      Format.fprintf formatter "%sInsert(%s)@\n" prefix table;
      format_at formatter (indent + 1) source
  | Unqualify { input } ->
      Format.fprintf formatter "%sUnqualify@\n" prefix;
      format_at formatter (indent + 1) input
  | Type_op { input } ->
      Format.fprintf formatter "%sType@\n" prefix;
      format_at formatter (indent + 1) input
  | Scalar_literal value ->
      Format.fprintf formatter "%sScalarLiteral(%a)@\n" prefix Scalar.format
        value
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
  | Drop_table { table_name } ->
      Format.fprintf formatter "%sDropTable(%s)@\n" prefix table_name
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
  | Catalog_source -> Format.fprintf formatter "%sCatalogSource@\n" prefix

let format formatter plan = format_at formatter 0 plan
