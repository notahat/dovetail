type op = Equal | NotEqual
type term = Column of string | Literal of Value.t
type t = Compare of { left : term; op : op; right : term }

(* The static kind that classifies a runtime value. Used to type-check the
   two sides of a [Compare] before building the per-row evaluator. *)
let kind_of_value = function
  | Value.Int64 _ -> Value.Kind.Int64
  | Value.String _ -> Value.Kind.String
  | Value.Bool _ -> Value.Kind.Bool

(* Render a [Value.Kind.t] for inclusion in error messages. *)
let kind_name = function
  | Value.Kind.Int64 -> "Int64"
  | Value.Kind.String -> "String"
  | Value.Kind.Bool -> "Bool"

(* Render a [term] for inclusion in error messages. Columns appear as their
   bare name; literals are tagged as such with their kind so the message
   makes sense even when the literal's printed form would be ambiguous. *)
let describe_term = function
  | Column name -> Printf.sprintf "column %S" name
  | Literal value ->
      Printf.sprintf "literal %s" (kind_name (kind_of_value value))

(* Resolve a [term] to (its kind, a function that reads its value from a
   tuple). For columns this captures the position once at resolve time so
   per-row evaluation is just an array index. *)
let resolve_term schema = function
  | Literal value ->
      let kind = kind_of_value value in
      let read_value (_tuple : Schema.tuple) = value in
      (kind, read_value)
  | Column column_name -> (
      match Schema.find_field schema column_name with
      | None ->
          failwith
            (Printf.sprintf "Predicate.resolve: unknown column %S" column_name)
      | Some (column_position, field) ->
          let read_value (tuple : Schema.tuple) = tuple.(column_position) in
          (field.kind, read_value))

let resolve schema (Compare { left; op; right }) =
  let left_kind, read_left = resolve_term schema left in
  let right_kind, read_right = resolve_term schema right in
  if left_kind <> right_kind then
    failwith
      (Printf.sprintf "Predicate.resolve: type mismatch: %s is %s, %s is %s"
         (describe_term left) (kind_name left_kind) (describe_term right)
         (kind_name right_kind));
  let comparator = match op with Equal -> ( = ) | NotEqual -> ( <> ) in
  fun (tuple : Schema.tuple) -> comparator (read_left tuple) (read_right tuple)
