module Scalar = Dovetail_core.Scalar
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

type column_reference = { qualifier : string option; name : string }

let format_column_reference = function
  | { qualifier = Some qualifier; name } -> qualifier ^ "." ^ name
  | { qualifier = None; name } -> name

type type_field = {
  qualifier : string option;
  name : string;
  kind : Scalar.kind;
}

type refinement = Primary_key of column_reference list

type type_expression = {
  fields : type_field list;
  refinements : refinement list;
}

type projection = column_reference list

type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : Expression.t }
  | Project of { input : t; columns : projection }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : Expression.t }
  | Insert of { table : string; source : t }
  | Unqualify of { input : t }
  | Type of { input : t }
  | Scalar_literal of Scalar.value
  | Row_literal of (column_reference * Scalar.value) list
  | Drop_table of { table_name : string }
  | Create_table_empty of {
      table_name : string;
      type_expression : type_expression;
    }
  | Create_table_seeded of { table_name : string; source : t }
  | Relation_literal of {
      relation_type : type_expression;
      rows : (column_reference * Scalar.value) list list;
    }
  | Catalog_source
  | Tables of { input : t }
