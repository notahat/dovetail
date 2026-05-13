type comparison_op = Equal | NotEqual

type t =
  | Literal of Value.t
  | Column of Schema.column_reference
  | Compare of { left : t; op : comparison_op; right : t }

(* Render an expression node for inclusion in kind-mismatch error messages.
   Columns and literals get source-flavoured descriptions matching the
   existing error wording; comparisons fall back to a generic label, since
   the parser does not produce nested comparisons today. *)
let describe_expression = function
  | Column reference ->
      Printf.sprintf "column %S" (Schema.format_column_reference reference)
  | Literal value ->
      Printf.sprintf "literal %s" (Value.Kind.to_string (Value.kind_of value))
  | Compare _ -> "comparison expression"

(* Render a [Value.t] as a literal in source-like form: int64s as bare
   digits, strings double-quoted with no escaping, bools as the keywords
   [true] and [false]. Used by the pretty-printer; not intended to
   round-trip through the parser (string escapes aren't handled). *)
let render_literal = function
  | Value.Int64 number -> Int64.to_string number
  | Value.String text -> "\"" ^ text ^ "\""
  | Value.Bool true -> "true"
  | Value.Bool false -> "false"

let render_op = function Equal -> "=" | NotEqual -> "<>"

let rec format formatter = function
  | Column reference ->
      Format.pp_print_string formatter
        (Schema.format_column_reference reference)
  | Literal value -> Format.pp_print_string formatter (render_literal value)
  | Compare { left; op; right } ->
      Format.fprintf formatter "%a %s %a" format left (render_op op) format
        right

(* Walk [expression] once, producing the value-producing closure paired with
   the value's static kind. Each [Column] is resolved against [schema] here,
   so per-tuple evaluation is just an array index. Kind mismatches inside a
   [Compare] are reported here, naming both operands via
   {!describe_expression}. *)
let rec resolve_value schema = function
  | Literal value ->
      let kind = Value.kind_of value in
      let read (_tuple : Schema.tuple) = value in
      (kind, read)
  | Column reference -> (
      match Schema.find_field schema reference with
      | Error message -> failwith ("Expression.resolve: " ^ message)
      | Ok (column_position, field) ->
          let read (tuple : Schema.tuple) = tuple.(column_position) in
          (field.kind, read))
  | Compare { left; op; right } ->
      let left_kind, read_left = resolve_value schema left in
      let right_kind, read_right = resolve_value schema right in
      if left_kind <> right_kind then
        failwith
          (Printf.sprintf
             "Expression.resolve: type mismatch: %s is %s, %s is %s"
             (describe_expression left)
             (Value.Kind.to_string left_kind)
             (describe_expression right)
             (Value.Kind.to_string right_kind));
      let comparator = match op with Equal -> ( = ) | NotEqual -> ( <> ) in
      let read tuple =
        Value.Bool (comparator (read_left tuple) (read_right tuple))
      in
      (Value.Kind.Bool, read)

let resolve schema expression =
  let kind, read_value = resolve_value schema expression in
  if kind <> Value.Kind.Bool then
    failwith
      (Printf.sprintf
         "Expression.resolve: predicate position requires Bool, got %s"
         (Value.Kind.to_string kind));
  fun (tuple : Schema.tuple) ->
    (* The resolve-time kind check above guarantees a Bool value here. *)
    match read_value tuple with
    | Value.Bool flag -> flag
    | _ -> assert false
