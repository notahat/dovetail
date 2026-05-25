(* [Scalar] is the only module from outside [surface_ra] that the AST
   references. Scalar kinds and values are primitive tags and payloads carried
   verbatim from the surface; every other semantic type lives on the far side
   of Lower and the AST has no business naming them here. *)
module Scalar = Dovetail_core.Scalar

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

type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

type expression =
  | Literal of Scalar.value
  | Column of column_reference
  | Compare of { left : expression; op : comparison_op; right : expression }
  | And of expression * expression
  | Or of expression * expression
  | Not of expression

type t =
  | Relation_name of string
  | Restrict of { input : t; predicate : expression }
  | Project of { input : t; columns : projection }
  | CrossProduct of { left : t; right : t }
  | Join of { left : t; right : t; predicate : expression }
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
