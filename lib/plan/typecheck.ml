module Catalog = Dovetail_core.Catalog
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar

type error =
  | Insert_column_mismatch of {
      table_name : string;
      missing : string list;
      extra : string list;
    }
  | Insert_kind_mismatch of {
      table_name : string;
      column : string;
      expected : Scalar.kind;
      actual : Scalar.kind;
    }
  | Unresolved_column of {
      column_reference : Row.column_reference;
      available_row_kind : Row.kind;
      operator : string;
    }
  | Compare_kind_mismatch of {
      operator : string;
      left : Expression.t;
      left_kind : Scalar.kind;
      right : Expression.t;
      right_kind : Scalar.kind;
    }
  | Ordering_operator_on_unordered_kind of {
      operator : string;
      comparison_op : Expression.comparison_op;
      kind : Scalar.kind;
    }

(* Source-flavoured description of an expression node, used inside the
   renderer for [Compare_kind_mismatch]. Mirrors the wording the legacy
   [Expression.resolve]-time message used, so users see the same phrasing
   ("column %S", "literal %s") regardless of which layer reported the
   error. Compound arms fall back to a generic label -- today's grammar
   doesn't nest [Compare]/[And]/[Or]/[Not] under a [Compare]'s operand
   position, so they are not exercised in practice. *)
let describe_expression : Expression.t -> string = function
  | Column reference ->
      Printf.sprintf "column %S" (Row.format_column_reference reference)
  | Literal value ->
      Printf.sprintf "literal %s" (Scalar.kind_to_string (Scalar.kind_of value))
  | Compare _ -> "comparison expression"
  | And _ -> "and expression"
  | Or _ -> "or expression"
  | Not _ -> "not expression"

(* Render a comparison operator the way it appears in source. *)
let render_comparison_op : Expression.comparison_op -> string = function
  | Equal -> "="
  | NotEqual -> "<>"
  | Less -> "<"
  | LessEqual -> "<="
  | Greater -> ">"
  | GreaterEqual -> ">="

(* Ordering operators have a meaningful comparison only on kinds with a
   natural order. Mirrors [Expression]'s internal definition; duplicated
   here so [Typecheck] does not depend on private [Expression] helpers. *)
let is_ordering_op : Expression.comparison_op -> bool = function
  | Less | LessEqual | Greater | GreaterEqual -> true
  | Equal | NotEqual -> false

let is_ordered_kind : Scalar.kind -> bool = function
  | Int64 | String -> true
  | Bool -> false

(* Symmetric difference of [expected] and [actual] as two lists: the names
   in [expected] but not in [actual] and the names in [actual] but not in
   [expected]. Each result preserves the order of its source list. *)
let multiset_difference ~expected ~actual =
  let missing = List.filter (fun name -> not (List.mem name actual)) expected in
  let extra = List.filter (fun name -> not (List.mem name expected)) actual in
  (missing, extra)

let render = function
  | Insert_column_mismatch { table_name; missing; extra } ->
      let halves =
        (if missing = [] then []
         else
           [
             Printf.sprintf "missing column(s): %s" (String.concat ", " missing);
           ])
        @
        if extra = [] then []
        else
          [ Printf.sprintf "unknown column(s): %s" (String.concat ", " extra) ]
      in
      Printf.sprintf "Insert: into %S: %s" table_name
        (String.concat "; " halves)
  | Insert_kind_mismatch { table_name; column; expected; actual } ->
      Printf.sprintf "Insert: into %S: column %S expects %s, got %s" table_name
        column
        (Scalar.kind_to_string expected)
        (Scalar.kind_to_string actual)
  | Unresolved_column { column_reference; available_row_kind; operator } ->
      let detail =
        match Row.find_field available_row_kind column_reference with
        | Error message -> message
        (* Constructed only when resolution failed, so the lookup must
           fail the same way at render time. *)
        | Ok _ -> assert false
      in
      Printf.sprintf "%s: %s" operator detail
  | Compare_kind_mismatch { operator; left; left_kind; right; right_kind } ->
      Printf.sprintf "%s: type mismatch: %s is %s, %s is %s" operator
        (describe_expression left)
        (Scalar.kind_to_string left_kind)
        (describe_expression right)
        (Scalar.kind_to_string right_kind)
  | Ordering_operator_on_unordered_kind { operator; comparison_op; kind } ->
      Printf.sprintf "%s: ordering operator %s is not defined for %s" operator
        (render_comparison_op comparison_op)
        (Scalar.kind_to_string kind)

(* Check that [literal_kind]'s field names are a permutation of
   [target_kind]'s. Emits a single [Insert_column_mismatch] carrying both
   halves of the symmetric difference, so the renderer can produce one
   combined message rather than splitting the report into two passes. *)
let check_insert_columns ~table_name ~(target_kind : Relation.kind)
    ~(literal_kind : Relation.kind) : error list =
  let target_column_names =
    List.map (fun (field : Row.field) -> field.name) target_kind.row_kind
  in
  let literal_column_names =
    List.map (fun (field : Row.field) -> field.name) literal_kind.row_kind
  in
  let missing, extra =
    multiset_difference ~expected:target_column_names
      ~actual:literal_column_names
  in
  if missing = [] && extra = [] then []
  else [ Insert_column_mismatch { table_name; missing; extra } ]

(* Check that each field in [literal_kind] has the same scalar kind as the
   target column with the same name. Emits one [Insert_kind_mismatch] per
   mismatching column, in source row-order.

   Precondition: column names have already agreed via
   [check_insert_columns], so every literal field has a matching target
   field. *)
let check_insert_value_kinds ~table_name ~(target_kind : Relation.kind)
    ~(literal_kind : Relation.kind) : error list =
  List.filter_map
    (fun (literal_field : Row.field) ->
      let target_field =
        List.find
          (fun (field : Row.field) -> field.name = literal_field.name)
          target_kind.row_kind
      in
      if literal_field.kind = target_field.kind then None
      else
        Some
          (Insert_kind_mismatch
             {
               table_name;
               column = literal_field.name;
               expected = target_field.kind;
               actual = literal_field.kind;
             }))
    literal_kind.row_kind

(* Errors specific to an [Insert] node: the literal source's column set
   against the target's, then per-column kind agreement. The kind check is
   skipped when the column-set check has already failed -- comparing
   value kinds against mismatched names produces noise. Unknown target
   tables pass through silently -- [Translate] still raises for those.
   Non-literal sources have no compile-time kind to check against here. *)
let check_insert ~(catalog : Catalog.kind) ~table ~(source : Logical.t) :
    error list =
  match (List.assoc_opt table catalog.relation_kinds, source) with
  | Some target_kind, Relation_literal { kind = literal_kind; _ } ->
      let column_errors =
        check_insert_columns ~table_name:table ~target_kind ~literal_kind
      in
      if column_errors <> [] then column_errors
      else check_insert_value_kinds ~table_name:table ~target_kind ~literal_kind
  | _ -> []

(* Fixed result kinds for the mutation and catalog-projecting operators,
   mirroring the values their evaluators hand back. Kept inline here so
   [kind_of] does not pull a dependency on [Physical]. *)
let insert_result_kind : Relation.kind =
  {
    row_kind =
      [ { name = "insert_count"; kind = Scalar.Int64; qualifier = None } ];
    refinements = [];
  }

let drop_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "dropped"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

let create_table_result_kind : Relation.kind =
  {
    row_kind = [ { name = "created"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

let tables_result_kind : Relation.kind =
  {
    row_kind = [ { name = "name"; kind = Scalar.String; qualifier = None } ];
    refinements = [];
  }

(* Best-effort static row kind of [plan]'s output, used by the walker to
   know what columns each operator's input exposes. Mirrors
   {!Plan.Physical.kind_of}'s shape on the parallel arms.

   Errors in the subtree are accepted: when an operator's kind cannot be
   computed cleanly (an [Unqualify] that would collide on stripping, a
   [Project] referring to an unknown column, a [Scan] of a missing
   table), [kind_of] returns a degraded but well-shaped kind rather than
   raising, so the walker can still report any further errors below. The
   degraded kind is good enough for downstream column-lookup checks --
   any reference resolved against it will either match a real available
   column or surface its own [Unresolved_column] error.

   Non-relation rungs ([Scalar_literal], [Row_literal], [Catalog_source],
   [Type_op]) raise [assert false] -- the walker never feeds those into
   an operator that needs a [Relation.kind] today. *)
let rec kind_of ~(catalog : Catalog.kind) (plan : Logical.t) : Relation.kind =
  match plan with
  | Scan { table } -> (
      match List.assoc_opt table catalog.relation_kinds with
      | Some kind -> kind
      | None -> { row_kind = []; refinements = [] })
  | Restrict { input; _ } -> kind_of ~catalog input
  | Project { input; columns } -> (
      try
        let projected_kind, _project_row =
          Projection.resolve (kind_of ~catalog input) columns
        in
        projected_kind
      with Failure _ -> { row_kind = []; refinements = [] })
  | CrossProduct { left; right } ->
      let left_row_kind = (kind_of ~catalog left).row_kind in
      let right_row_kind = (kind_of ~catalog right).row_kind in
      { row_kind = left_row_kind @ right_row_kind; refinements = [] }
  | Relation_literal { kind; rows = _ } -> kind
  | Insert _ -> insert_result_kind
  | Unqualify { input } -> (
      let input_kind = kind_of ~catalog input in
      match Row.unqualify_kind input_kind.row_kind with
      | Ok row_kind -> { row_kind; refinements = input_kind.refinements }
      | Error _ -> input_kind)
  | Drop_table _ -> drop_table_result_kind
  | Create_table_empty _ | Create_table_seeded _ -> create_table_result_kind
  | Tables _ -> tables_result_kind
  | Type_op _ | Scalar_literal _ | Row_literal _ | Catalog_source ->
      (* A relational sub-plan never has one of these as its input today;
         every walker arm that asks for [kind_of] is one whose surrounding
         operator demands a relation. *)
      assert false

(* Static scalar kind of [expression] under [row_kind], or [None] when the
   kind cannot be determined cleanly (currently: an unresolved [Column]
   reference). [Compare] / [And] / [Or] / [Not] structurally return [Bool]
   regardless of whether their own validation passes, so kind-derivation
   for those nodes never cascades a [None] upward. *)
let expression_kind ~row_kind (expression : Expression.t) : Scalar.kind option =
  match expression with
  | Literal value -> Some (Scalar.kind_of value)
  | Column reference -> (
      match Row.find_field row_kind reference with
      | Ok (_position, field) -> Some field.kind
      | Error _ -> None)
  | Compare _ | And _ | Or _ | Not _ -> Some Scalar.Bool

(* Errors specific to a single [Compare] node: kind agreement between the
   two operand sub-expressions, then ordering-operator compatibility
   against the agreed kind. Skips the ordering check when the mismatch
   error has already fired, mirroring the legacy [Expression.resolve]
   ordering and avoiding noise atop noise. *)
let check_compare ~operator ~row_kind ~left ~op ~right : error list =
  match (expression_kind ~row_kind left, expression_kind ~row_kind right) with
  | Some left_kind, Some right_kind when left_kind <> right_kind ->
      [ Compare_kind_mismatch { operator; left; left_kind; right; right_kind } ]
  | Some shared_kind, Some _
    when is_ordering_op op && not (is_ordered_kind shared_kind) ->
      [
        Ordering_operator_on_unordered_kind
          { operator; comparison_op = op; kind = shared_kind };
      ]
  | _ -> []

(* Walk [expression] once, accumulating every typecheck error it carries.
   Covers unresolved column references at every [Column] node plus
   per-[Compare] kind and ordering checks. [operator] becomes the
   user-facing prefix on every error emitted by this walk. *)
let rec check_expression ~operator ~row_kind (expression : Expression.t) :
    error list =
  match expression with
  | Literal _ -> []
  | Column reference -> (
      match Row.find_field row_kind reference with
      | Ok _ -> []
      | Error _ ->
          [
            Unresolved_column
              {
                column_reference = reference;
                available_row_kind = row_kind;
                operator;
              };
          ])
  | Compare { left; op; right } ->
      let left_errors = check_expression ~operator ~row_kind left in
      let right_errors = check_expression ~operator ~row_kind right in
      let compare_errors = check_compare ~operator ~row_kind ~left ~op ~right in
      left_errors @ right_errors @ compare_errors
  | And (left, right) | Or (left, right) ->
      check_expression ~operator ~row_kind left
      @ check_expression ~operator ~row_kind right
  | Not operand -> check_expression ~operator ~row_kind operand

(* For each column reference [references] holds, emit an [Unresolved_column]
   error when it does not resolve to exactly one field of [row_kind].
   [operator] becomes the error's user-facing prefix. Used for the bare
   column-reference lists projections carry. *)
let check_column_references ~operator ~row_kind references : error list =
  List.filter_map
    (fun reference ->
      match Row.find_field row_kind reference with
      | Ok _ -> None
      | Error _ ->
          Some
            (Unresolved_column
               {
                 column_reference = reference;
                 available_row_kind = row_kind;
                 operator;
               }))
    references

(* Post-order walk: gather errors from each subtree, then add any errors
   contributed by the operator itself. *)
let rec collect_errors ~catalog (plan : Logical.t) : error list =
  match plan with
  | Scan _ | Relation_literal _ | Scalar_literal _ | Row_literal _
  | Drop_table _ | Create_table_empty _ | Catalog_source ->
      []
  | Unqualify { input }
  | Type_op { input }
  | Tables { input }
  | Create_table_seeded { source = input; _ } ->
      collect_errors ~catalog input
  | Project { input; columns } ->
      let input_errors = collect_errors ~catalog input in
      let input_row_kind = (kind_of ~catalog input).row_kind in
      let column_errors =
        check_column_references ~operator:"Project" ~row_kind:input_row_kind
          columns
      in
      input_errors @ column_errors
  | Restrict { input; predicate } ->
      let input_errors = collect_errors ~catalog input in
      let input_row_kind = (kind_of ~catalog input).row_kind in
      let predicate_errors =
        check_expression ~operator:"Restrict" ~row_kind:input_row_kind predicate
      in
      input_errors @ predicate_errors
  | CrossProduct { left; right } ->
      collect_errors ~catalog left @ collect_errors ~catalog right
  | Insert { table; source } ->
      let source_errors = collect_errors ~catalog source in
      let insert_errors = check_insert ~catalog ~table ~source in
      source_errors @ insert_errors

let typecheck ~catalog plan =
  match collect_errors ~catalog plan with
  | [] -> Ok plan
  | errors -> Error errors
