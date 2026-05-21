type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

type t =
  | Literal of Value.data
  | Column of Schema.column_reference
  | Compare of { left : t; op : comparison_op; right : t }
  | And of t * t
  | Or of t * t
  | Not of t

(* Render an expression node for inclusion in kind-mismatch error messages.
   Columns and literals get source-flavoured descriptions matching the
   existing error wording; compound nodes fall back to generic labels.

   Pre: the parser does not nest [Compare]/[And]/[Or]/[Not] inside a
   [Compare]'s operand position, so the compound arms are never reached
   from kind-mismatch reporting today. If a future grammar widens operand
   shapes, revisit those arms to give them source-flavoured descriptions
   too. *)
let describe_expression = function
  | Column reference ->
      Printf.sprintf "column %S" (Schema.format_column_reference reference)
  | Literal value ->
      Printf.sprintf "literal %s" (Value.kind_to_string (Value.kind_of value))
  | Compare _ -> "comparison expression"
  | And _ -> "and expression"
  | Or _ -> "or expression"
  | Not _ -> "not expression"

let render_op = function
  | Equal -> "="
  | NotEqual -> "<>"
  | Less -> "<"
  | LessEqual -> "<="
  | Greater -> ">"
  | GreaterEqual -> ">="

(* Ordering operators only apply to kinds with a meaningful order. Today
   that is [Int64] and [String]; [Bool] is excluded. *)
let is_ordered_kind : Value.kind -> bool = function
  | Int64 | String -> true
  | Bool -> false

let is_ordering_op = function
  | Less | LessEqual | Greater | GreaterEqual -> true
  | Equal | NotEqual -> false

(* Pretty-printer precedence levels, higher value binds tighter. The
   formatter wraps a sub-expression in parens when its precedence is
   below the surrounding context's minimum -- that keeps the rendering
   unambiguous when re-parsed. *)
let precedence_or = 1
let precedence_and = 2
let precedence_not = 3
let precedence_compare = 4
let precedence_atom = 5

let precedence_of = function
  | Literal _ | Column _ -> precedence_atom
  | Compare _ -> precedence_compare
  | Not _ -> precedence_not
  | And _ -> precedence_and
  | Or _ -> precedence_or

(* Render [expression] inside a context that requires at least
   [min_precedence]. Below the minimum, wrap in parens and recurse with
   a fresh context. Above or equal, render the node directly.

   For each left-associative binary operator the right operand is
   rendered at one precedence level higher than the left, so a same-
   precedence node on the right is parenthesised to preserve meaning
   when re-parsed. *)
let rec format_at min_precedence formatter expression =
  let precedence = precedence_of expression in
  if precedence < min_precedence then
    Format.fprintf formatter "(%a)" (format_at 0) expression
  else
    match expression with
    | Literal value -> Value.format formatter value
    | Column reference ->
        Format.pp_print_string formatter
          (Schema.format_column_reference reference)
    | Compare { left; op; right } ->
        Format.fprintf formatter "%a %s %a"
          (format_at (precedence_compare + 1))
          left (render_op op)
          (format_at (precedence_compare + 1))
          right
    | And (left, right) ->
        Format.fprintf formatter "%a and %a" (format_at precedence_and) left
          (format_at (precedence_and + 1))
          right
    | Or (left, right) ->
        Format.fprintf formatter "%a or %a" (format_at precedence_or) left
          (format_at (precedence_or + 1))
          right
    | Not operand ->
        Format.fprintf formatter "not %a" (format_at precedence_not) operand

let format formatter expression = format_at 0 formatter expression

(* Common helper for [And] and [Or]: the operator name (for the error
   message) and the kind check on a single operand. *)
let check_bool_operand operator_name operand (kind : Value.kind) =
  if kind <> Value.Bool then
    failwith
      (Printf.sprintf "Expression.resolve: %s requires Bool operands: %s is %s"
         operator_name
         (describe_expression operand)
         (Value.kind_to_string kind))

(* Walk [expression] once, producing the value-producing closure paired with
   the value's static kind. Each [Column] is resolved against [schema] here,
   so per-tuple evaluation is just an array index. Kind mismatches inside a
   [Compare] are reported here, naming both operands via
   {!describe_expression}; [And]/[Or] operands are checked for {!Bool} kind
   in the same way. Short-circuit evaluation for [And]/[Or] is built into
   the produced closure: the right operand is only read when the left's
   verdict doesn't determine the result. *)
let rec resolve_value schema : t -> Value.kind * (Schema.tuple -> Value.data) =
 fun expression ->
  match expression with
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
             (Value.kind_to_string left_kind)
             (describe_expression right)
             (Value.kind_to_string right_kind));
      if is_ordering_op op && not (is_ordered_kind left_kind) then
        failwith
          (Printf.sprintf
             "Expression.resolve: ordering operator %s is not defined for %s"
             (render_op op)
             (Value.kind_to_string left_kind));
      let comparator =
        match op with
        | Equal -> ( = )
        | NotEqual -> ( <> )
        | Less -> ( < )
        | LessEqual -> ( <= )
        | Greater -> ( > )
        | GreaterEqual -> ( >= )
      in
      let read tuple =
        Value.Bool (comparator (read_left tuple) (read_right tuple))
      in
      (Value.Bool, read)
  | And (left, right) ->
      let left_kind, read_left = resolve_value schema left in
      let right_kind, read_right = resolve_value schema right in
      check_bool_operand "and" left left_kind;
      check_bool_operand "and" right right_kind;
      let read tuple =
        (* Short-circuit: the right operand is only read when the left is
           true. The two non-Bool cases are unreachable given the kind
           checks above. *)
        match read_left tuple with
        | Value.Bool false -> Value.Bool false
        | Value.Bool true -> read_right tuple
        | _ -> assert false
      in
      (Value.Bool, read)
  | Or (left, right) ->
      let left_kind, read_left = resolve_value schema left in
      let right_kind, read_right = resolve_value schema right in
      check_bool_operand "or" left left_kind;
      check_bool_operand "or" right right_kind;
      let read tuple =
        match read_left tuple with
        | Value.Bool true -> Value.Bool true
        | Value.Bool false -> read_right tuple
        | _ -> assert false
      in
      (Value.Bool, read)
  | Not operand ->
      let operand_kind, read_operand = resolve_value schema operand in
      if operand_kind <> Value.Bool then
        failwith
          (Printf.sprintf
             "Expression.resolve: not requires a Bool operand: %s is %s"
             (describe_expression operand)
             (Value.kind_to_string operand_kind));
      let read tuple =
        match read_operand tuple with
        | Value.Bool true -> Value.Bool false
        | Value.Bool false -> Value.Bool true
        | _ -> assert false
      in
      (Value.Bool, read)

let resolve schema expression =
  let kind, read_value = resolve_value schema expression in
  if kind <> Value.Bool then
    failwith
      (Printf.sprintf
         "Expression.resolve: predicate position requires Bool, got %s"
         (Value.kind_to_string kind));
  fun (tuple : Schema.tuple) ->
    (* The resolve-time kind check above guarantees a Bool value here. *)
    match read_value tuple with
    | Value.Bool flag -> flag
    | _ -> assert false
