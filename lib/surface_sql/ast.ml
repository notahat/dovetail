module Scalar = Dovetail_core.Scalar

type column_reference = { qualifier : string option; name : string }

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

type select_list = All | Columns of column_reference list

type t =
  | Select of {
      select_list : select_list;
      from : string;
      where : expression option;
    }
