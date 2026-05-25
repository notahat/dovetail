type comparison_op =
  | Equal
  | NotEqual
  | Less
  | LessEqual
  | Greater
  | GreaterEqual

type t =
  | Literal of Scalar.value
  | Column of Row.column_reference
  | Compare of { left : t; op : comparison_op; right : t }
  | And of t * t
  | Or of t * t
  | Not of t

let render_op = function
  | Equal -> "="
  | NotEqual -> "<>"
  | Less -> "<"
  | LessEqual -> "<="
  | Greater -> ">"
  | GreaterEqual -> ">="

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
    | Literal value -> Scalar.format formatter value
    | Column reference ->
        Format.pp_print_string formatter (Row.format_column_reference reference)
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

(* Walk [expression] once, producing the value-producing closure paired
   with the value's static kind. The closure shape is the whole point:
   name lookups and operator dispatch happen here, and the closure
   captures only the resolved positions and primitive operators it
   needs, so the per-row caller does no name lookup and pays only array
   indices plus structural compares. Short-circuit evaluation for
   [And] / [Or] is built into the produced closure: the right operand
   is only read when the left's verdict doesn't determine the result.

   Pre: [expression] has been validated by [Plan.Typecheck] -- every
   [Column] reference resolves uniquely, every [Compare]'s operands
   agree on kind and (for ordering operators) the kind is ordered, and
   every [And] / [Or] / [Not] operand has kind [Bool]. The [assert
   false] arms below mark places where Typecheck's guarantees keep
   bad cases from reaching the closure. *)
let rec resolve_value row_kind : t -> Scalar.kind * (Row.value -> Scalar.value)
    =
 fun expression ->
  match expression with
  | Literal value ->
      let kind = Scalar.kind_of value in
      let read (_row : Row.value) = value in
      (kind, read)
  | Column reference -> (
      match Row.find_field row_kind reference with
      | Ok (column_position, field) ->
          let read (row : Row.value) = row.(column_position) in
          (field.kind, read)
      (* Typecheck has resolved every column reference; the Error arm is
         unreachable. *)
      | Error _ -> assert false)
  | Compare { left; op; right } ->
      let _left_kind, read_left = resolve_value row_kind left in
      let _right_kind, read_right = resolve_value row_kind right in
      let comparator =
        match op with
        | Equal -> ( = )
        | NotEqual -> ( <> )
        | Less -> ( < )
        | LessEqual -> ( <= )
        | Greater -> ( > )
        | GreaterEqual -> ( >= )
      in
      let read row =
        Scalar.Bool (comparator (read_left row) (read_right row))
      in
      (Scalar.Bool, read)
  | And (left, right) ->
      let _left_kind, read_left = resolve_value row_kind left in
      let _right_kind, read_right = resolve_value row_kind right in
      let read row =
        (* Short-circuit: the right operand is only read when the left is
           true. Typecheck guarantees Bool operands; non-Bool arms are
           unreachable. *)
        match read_left row with
        | Scalar.Bool false -> Scalar.Bool false
        | Scalar.Bool true -> read_right row
        | _ -> assert false
      in
      (Scalar.Bool, read)
  | Or (left, right) ->
      let _left_kind, read_left = resolve_value row_kind left in
      let _right_kind, read_right = resolve_value row_kind right in
      let read row =
        (* Short-circuit: the right operand is only read when the left is
           false. Typecheck guarantees Bool operands; non-Bool arms are
           unreachable. *)
        match read_left row with
        | Scalar.Bool true -> Scalar.Bool true
        | Scalar.Bool false -> read_right row
        | _ -> assert false
      in
      (Scalar.Bool, read)
  | Not operand ->
      let _operand_kind, read_operand = resolve_value row_kind operand in
      let read row =
        (* Typecheck guarantees a Bool operand; the non-Bool arm is
           unreachable. *)
        match read_operand row with
        | Scalar.Bool true -> Scalar.Bool false
        | Scalar.Bool false -> Scalar.Bool true
        | _ -> assert false
      in
      (Scalar.Bool, read)

let resolve row_kind expression =
  let _kind, read_value = resolve_value row_kind expression in
  fun (row : Row.value) ->
    (* Typecheck guarantees the top expression has kind Bool; the
       non-Bool arm is unreachable. *)
    match read_value row with
    | Scalar.Bool flag -> flag
    | _ -> assert false
