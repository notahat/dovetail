type op = Equal | NotEqual
type term = Column of Schema.column_reference | Literal of Value.t
type t = Compare of { left : term; op : op; right : term }

(* Render a [term] for inclusion in error messages. Columns appear in their
   source form (bare or dotted); literals are tagged as such with their kind
   so the message makes sense even when the literal's printed form would be
   ambiguous. *)
let describe_term = function
  | Column reference ->
      Printf.sprintf "column %S" (Schema.format_column_reference reference)
  | Literal value ->
      Printf.sprintf "literal %s" (Value.Kind.to_string (Value.kind_of value))

(* Resolve a [term] to (its kind, a function that reads its value from a
   tuple). For columns this captures the position once at resolve time so
   per-row evaluation is just an array index. *)
let resolve_term schema = function
  | Literal value ->
      let kind = Value.kind_of value in
      let read_value (_tuple : Schema.tuple) = value in
      (kind, read_value)
  | Column reference -> (
      match Schema.find_field schema reference with
      | Error message -> failwith ("Predicate.resolve: " ^ message)
      | Ok (column_position, field) ->
          let read_value (tuple : Schema.tuple) = tuple.(column_position) in
          (field.kind, read_value))

(* Render a [Value.t] as a literal in source-like form: int64s as bare
   digits, strings double-quoted with no escaping, bools as the keywords
   [true] and [false]. Used by the predicate pretty-printer; not intended
   to round-trip through the parser (string escapes aren't handled). *)
let render_literal = function
  | Value.Int64 number -> Int64.to_string number
  | Value.String text -> "\"" ^ text ^ "\""
  | Value.Bool true -> "true"
  | Value.Bool false -> "false"

let render_term = function
  | Column reference -> Schema.format_column_reference reference
  | Literal value -> render_literal value

let render_op = function Equal -> "=" | NotEqual -> "<>"

let format formatter (Compare { left; op; right }) =
  Format.fprintf formatter "%s %s %s" (render_term left) (render_op op)
    (render_term right)

let resolve schema (Compare { left; op; right }) =
  let left_kind, read_left = resolve_term schema left in
  let right_kind, read_right = resolve_term schema right in
  if left_kind <> right_kind then
    failwith
      (Printf.sprintf "Predicate.resolve: type mismatch: %s is %s, %s is %s"
         (describe_term left)
         (Value.Kind.to_string left_kind)
         (describe_term right)
         (Value.Kind.to_string right_kind));
  let comparator = match op with Equal -> ( = ) | NotEqual -> ( <> ) in
  fun (tuple : Schema.tuple) -> comparator (read_left tuple) (read_right tuple)
