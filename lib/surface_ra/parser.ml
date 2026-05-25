open Angstrom
module StringSet = Set.Make (String)
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Expression = Dovetail_core.Expression
module Ddl = Dovetail_ddl

type error = string

let is_letter character =
  (character >= 'a' && character <= 'z')
  || (character >= 'A' && character <= 'Z')

let is_digit character = character >= '0' && character <= '9'

let is_identifier_continuation character =
  is_letter character || is_digit character || character = '_'

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

(* Consume zero or more whitespace characters. The parser succeeds even if
   no whitespace is present, so it can be used as an optional separator. *)
let whitespace = skip_while is_whitespace

(* An identifier: one letter, then any number of letters, digits, or
   underscores. Returned as a plain string; the AST wrapper is applied by
   the caller. *)
let identifier =
  satisfy is_letter >>= fun first_character ->
  take_while is_identifier_continuation >>| fun continuation ->
  String.make 1 first_character ^ continuation

(* Match a keyword: the literal [name], plus a word break (a non-identifier
   character or end of input) afterwards. The break is what stops
   [restrict_user] from sneakily matching the [restrict] keyword. *)
let keyword name =
  string name
  *> ( peek_char >>= function
       | None -> return ()
       | Some character when not (is_identifier_continuation character) ->
           return ()
       | Some _ -> fail (Printf.sprintf "expected end of keyword %S" name) )

(* A signed int64 literal: optional leading minus, then one or more digits.
   Fails (rather than producing a wrong value) on inputs that overflow
   int64, since [Int64.of_string_opt] handles range checking for us. *)
let int64_literal =
  option "" (string "-") >>= fun sign ->
  take_while1 is_digit >>= fun digits ->
  match Int64.of_string_opt (sign ^ digits) with
  | Some number -> return (Scalar.Int64 number)
  | None -> fail "int64 literal out of range"

(* A bool literal. The [keyword] helper enforces a word break after the
   literal text, so [trueish] doesn't sneakily match [true]. *)
let bool_literal =
  keyword "true" *> return (Scalar.Bool true)
  <|> keyword "false" *> return (Scalar.Bool false)

(* A character inside a string literal: either a recognised escape
   (backslash-quote or double-backslash) or any non-quote,
   non-backslash character. *)
let string_literal_character =
  char '\\'
  *> (char '"' *> return '"'
     <|> char '\\' *> return '\\'
     <|> fail "unrecognised escape sequence")
  <|> satisfy (fun character -> character <> '"' && character <> '\\')

(* A double-quoted string literal. The only recognised escapes are
   backslash-quote and double-backslash; anything else after a backslash
   is a parse error rather than a silently-accepted unknown escape. *)
let string_literal =
  char '"' *> many string_literal_character <* char '"' >>| fun characters ->
  let buffer = Buffer.create 16 in
  List.iter (Buffer.add_char buffer) characters;
  Scalar.String (Buffer.contents buffer)

(* A single literal value in a relation literal's value position: int,
   string, or bool. The dispatch on the leading character matches the
   [term] parser inside [expression]; bare identifiers (column references)
   are deliberately not accepted here -- the design doc reserves the
   value position for expressions, but in insert context columns have no
   row to resolve against, so until an expression IR is wired into the
   value position the surface form is "literal." *)
let literal_value =
  peek_char >>= function
  | Some '"' -> string_literal
  | Some '-' -> int64_literal
  | Some character when is_digit character -> int64_literal
  | Some character when is_letter character -> bool_literal
  | _ -> fail "expected a literal value (number, string, or bool)"

(* A column reference: either a bare identifier (unqualified) or two
   identifiers separated by a dot with no whitespace around it (qualified).
   The no-whitespace rule on the dot keeps the syntax disjoint from a future
   floating-point literal grammar. Used both in expression positions and in
   row-literal field positions. *)
let column_reference =
  identifier >>= fun first ->
  peek_char >>= function
  | Some '.' ->
      char '.' *> identifier >>| fun second ->
      ({ qualifier = Some first; name = second } : Row.column_reference)
  | _ -> return ({ qualifier = None; name = first } : Row.column_reference)

(* One [name = value] or [qualifier.name = value] binding inside a row
   literal. Returns the column reference alongside its scalar value;
   whitespace around the [=] is tolerated. *)
let row_literal_field =
  column_reference >>= fun reference ->
  whitespace *> char '=' *> whitespace *> literal_value >>| fun value ->
  (reference, value)

(* Raise a parse error if [fields] has two entries with the same qualified
   name -- the dotted [qualifier.name] form when present, the bare [name]
   otherwise. Distinct qualifiers on the same bare name are allowed
   ([users.id] and [orders.id] coexist), since their qualified names
   differ. The error names the first duplicate's qualified spelling so the
   user can find it. *)
let check_for_duplicate_row_fields fields =
  let rec walk seen = function
    | [] -> return ()
    | (reference, _) :: _
      when StringSet.mem (Row.format_column_reference reference) seen ->
        fail
          (Printf.sprintf "duplicate field %S in row literal"
             (Row.format_column_reference reference))
    | (reference, _) :: rest ->
        walk (StringSet.add (Row.format_column_reference reference) seen) rest
  in
  walk StringSet.empty fields

(* The lowercase kind keywords [int64], [string], and [bool] inside a type
   expression. Distinct from the capitalised identifiers [Int64] / [String]
   / [Bool] used by the [:create table] grammar; the two surfaces are
   converging on the lowercase form but the legacy DDL parser still owns
   the capitalised one. *)
let type_expression_kind_keyword =
  keyword "int64" *> return (Scalar.Int64 : Scalar.kind)
  <|> keyword "string" *> return (Scalar.String : Scalar.kind)
  <|> keyword "bool" *> return (Scalar.Bool : Scalar.kind)

(* Reserved words inside a type expression: the kind keywords and the
   refinement-clause keywords. A field name matching one of these is a parse
   error so the surface stays unambiguous as more refinement clauses arrive. *)
let type_expression_reserved_words =
  StringSet.of_list [ "int64"; "string"; "bool"; "primary"; "key" ]

(* The body of a [primary key (col, col, ...)] refinement: a non-empty,
   comma-separated list of column names with a permitted trailing comma. *)
let primary_key_columns =
  identifier >>= fun first_column ->
  many (whitespace *> char ',' *> whitespace *> identifier)
  >>= fun more_columns ->
  whitespace *> option false (char ',' *> return true) *> return ()
  >>| fun () -> first_column :: more_columns

(* A single item inside a type expression: either a field binding
   ([name: kind] or [qualifier.name: kind]) or a [primary key (...)]
   refinement. The leading identifier and the lookahead character together
   disambiguate the three shapes: a leading [primary] with no dot introduces
   the refinement clause; an identifier followed by [.] is the qualifier of
   a qualified field name; anything else is an unqualified field name.
   Reserved words are rejected at the bare-name position; in the qualified
   form the reserved-word check applies to the name half, since the
   qualifier prefix already disambiguates from the kind keyword and the
   refinement keyword. *)
let type_expression_item =
  identifier >>= fun first_word ->
  peek_char >>= function
  | Some '.' ->
      char '.' *> identifier >>= fun field_name ->
      if StringSet.mem field_name type_expression_reserved_words then
        fail
          (Printf.sprintf "%S is reserved as a keyword inside a type expression"
             field_name)
      else
        whitespace *> char ':' *> whitespace *> type_expression_kind_keyword
        >>| fun field_kind ->
        `Field
          ({ qualifier = Some first_word; name = field_name; kind = field_kind }
            : Ast.type_field)
  | _ ->
      if first_word = "primary" then
        whitespace *> keyword "key" *> whitespace *> char '(' *> whitespace
        *> primary_key_columns
        <* whitespace <* char ')'
        >>| fun columns -> `Refinement (Relation.Primary_key columns)
      else if StringSet.mem first_word type_expression_reserved_words then
        fail
          (Printf.sprintf "%S is reserved as a keyword inside a type expression"
             first_word)
      else
        whitespace *> char ':' *> whitespace *> type_expression_kind_keyword
        >>| fun field_kind ->
        `Field
          ({ qualifier = None; name = first_word; kind = field_kind }
            : Ast.type_field)

(* A parenthesised type-expression body: zero or more comma-separated items
   with a permitted trailing comma, or the empty form [()]. Returns the items
   in source order so the row-type entry point can scan for refinements. *)
let type_expression_items =
  whitespace
  *> ( peek_char >>= function
       | Some ')' -> return []
       | _ ->
           type_expression_item >>= fun first_item ->
           many (whitespace *> char ',' *> whitespace *> type_expression_item)
           >>= fun more_items ->
           whitespace *> option false (char ',' *> return true) *> return ()
           >>| fun () -> first_item :: more_items )

(* The shared parenthesised type-expression grammar. The row / relation
   distinction lives in the caller, which decides whether refinements are
   tolerated. *)
let type_expression_body =
  char '(' *> type_expression_items <* whitespace <* char ')'

(* Split the item list into fields and refinements, preserving source order
   within each bucket. The interleaved surface form means refinements can
   appear anywhere in the list, but the AST keeps the two buckets separate. *)
let partition_type_expression_items items =
  let fields =
    List.filter_map
      (function `Field field -> Some field | `Refinement _ -> None)
      items
  in
  let refinements =
    List.filter_map
      (function `Refinement refinement -> Some refinement | `Field _ -> None)
      items
  in
  (fields, refinements)

(* The parenthesised body of a row literal: [(name = value, ...)]. Returns
   the parsed fields without wrapping them in an AST node, so callers can
   either build an [Ast.Row_literal] (at pipeline-source position) or use
   the fields as a row payload inside a [relation (...) { ... }] literal.
   The empty form [()] parses to an empty field list. *)
let row_literal_body =
  char '(' *> whitespace
  *> ( peek_char >>= function
       | Some ')' -> return []
       | _ ->
           row_literal_field >>= fun first_field ->
           many (whitespace *> char ',' *> whitespace *> row_literal_field)
           >>= fun more_fields ->
           whitespace *> option false (char ',' *> return true) *> return ()
           >>| fun () -> first_field :: more_fields )
  <* whitespace <* char ')'
  >>= fun fields ->
  check_for_duplicate_row_fields fields >>| fun () -> fields

(* A row literal at pipeline-source position. Disambiguated from a future
   grouped expression by the [=] inside each field; at pipeline-source
   position only the row-literal form is admitted, so any non-empty parens
   that doesn't contain a [name = value] binding is a parse error. *)
let row_literal = row_literal_body >>| fun fields -> Ast.Row_literal fields

(* The body of a relation literal that follows the [relation] keyword:
   a parenthesised relation-type expression, then a brace-delimited list of
   row literals separated by commas with an optional trailing comma. The
   empty form [relation (T) {}] parses to [rows = []]. Field-name validation
   against the declared kind happens in {!Lower}; the parser checks only
   syntactic shape and per-row duplicates. *)
let relation_literal_body =
  whitespace *> type_expression_body >>= fun items ->
  let fields, refinements = partition_type_expression_items items in
  let kind : Relation.kind =
    {
      row_kind =
        List.map
          (fun ({ qualifier; name; kind } : Ast.type_field) : Row.field ->
            { name; kind; qualifier })
          fields;
      refinements;
    }
  in
  whitespace *> char '{' *> whitespace
  *> ( peek_char >>= function
       | Some '}' -> return []
       | _ ->
           row_literal_body >>= fun first_row ->
           many (whitespace *> char ',' *> whitespace *> row_literal_body)
           >>= fun more_rows ->
           whitespace *> option false (char ',' *> return true) *> return ()
           >>| fun () -> first_row :: more_rows )
  <* whitespace <* char '}'
  >>| fun rows -> Ast.Relation_literal { kind; rows }

(* The body of a [drop table <name>] leaf source: the caller has consumed
   the [drop] keyword; this parser commits to whitespace, the [table]
   keyword, more whitespace, and an identifier. A bare [drop] followed
   by anything else is a parse error, matching how the [relation] case
   commits to the literal grammar below -- a table called [drop] is a
   parse error in source position. *)
let drop_table_body =
  whitespace *> keyword "table" *> whitespace *> identifier
  >>| fun table_name -> Ast.Drop_table { table_name }

(* A bare identifier at pipeline-source position: a [true] / [false] scalar
   literal, the [relation] keyword introducing a relation literal, the
   [drop] keyword introducing a [drop table <name>] leaf, the bare [catalog]
   keyword yielding the catalog as a value, or a relation name. The leading-
   letter character class is shared, so we parse the identifier eagerly and
   dispatch on its spelling. The [relation] and [drop] cases commit to their
   respective sub-grammars; [catalog] is nullary and stands alone. *)
let identifier_relation_or_bool_literal =
  identifier >>= function
  | "true" -> return (Ast.Scalar_literal (Scalar.Bool true))
  | "false" -> return (Ast.Scalar_literal (Scalar.Bool false))
  | "relation" -> relation_literal_body
  | "drop" -> drop_table_body
  | "catalog" -> return Ast.Catalog_source
  | name -> return (Ast.Relation_name name)

(* The leading position of a pipeline: a row literal, a bare scalar literal,
   the [relation] keyword introducing a relation literal, or a relation name.
   Dispatched by lookahead on the leading character: an open paren introduces
   a row literal; a double quote, a minus, or a digit introduces a scalar
   literal; a letter is one of [true], [false], [relation], or a relation
   name. *)
let relation_expr =
  peek_char >>= function
  | Some '(' -> row_literal
  | Some '"' ->
      string_literal >>| fun literal_value -> Ast.Scalar_literal literal_value
  | Some '-' ->
      int64_literal >>| fun literal_value -> Ast.Scalar_literal literal_value
  | Some character when is_digit character ->
      int64_literal >>| fun literal_value -> Ast.Scalar_literal literal_value
  | _ -> identifier_relation_or_bool_literal

(* The six comparison operators. Dispatched by lookahead on the leading
   character, then for [<] and [>] by a second lookahead at the byte that
   follows. The two-stage dispatch keeps the choice between [<], [<=], and
   [<>] (and likewise between [>] and [>=]) unambiguous and independent of
   [<|>] backtracking behaviour. *)
let comparison_op =
  peek_char >>= function
  | Some '=' -> char '=' *> return Expression.Equal
  | Some '<' -> (
      char '<' *> peek_char >>= function
      | Some '>' -> char '>' *> return Expression.NotEqual
      | Some '=' -> char '=' *> return Expression.LessEqual
      | _ -> return Expression.Less)
  | Some '>' -> (
      char '>' *> peek_char >>= function
      | Some '=' -> char '=' *> return Expression.GreaterEqual
      | _ -> return Expression.Greater)
  | _ -> fail "expected a comparison operator"

(* The expression grammar, built bottom-up inside [fix] so the atom can
   recurse into the full expression via parens. Top-level layering, from
   loosest to tightest precedence, is [or_expression], [and_expression],
   [not_expression], [comparison_expression], and the atomic [term]. Parens
   around an expression appear in the atom position.

   The five tiers live as nested [let]s inside the single [fix] so the
   precedence chain reads top-to-bottom in one place. Each tier could be
   lifted to a top-level binding threading [~expression] -- the inner [fix]
   body would shrink considerably -- but the trade-off (parameter
   threading, five separate bindings to read in reverse precedence order
   to follow the chain) doesn't earn its keep until another tier or two
   of complexity arrives. The 35-line guideline is treated as a deliberate
   exception here, matching the precedent set by {!Physical.format_at}. *)
let expression =
  fix (fun expression ->
      (* A single atom: a literal, a column reference, or a parenthesised
       sub-expression. The bool literals [true] and [false] are spelled
       with letters that would otherwise start an identifier, so when
       the input starts with a letter we try the bool literal first and
       fall back to the column-reference parser. *)
      let term =
        peek_char >>= function
        | Some '"' ->
            string_literal >>| fun literal_value ->
            Expression.Literal literal_value
        | Some '-' ->
            int64_literal >>| fun literal_value ->
            Expression.Literal literal_value
        | Some character when is_digit character ->
            int64_literal >>| fun literal_value ->
            Expression.Literal literal_value
        | Some character when is_letter character ->
            bool_literal
            >>| (fun literal_value -> Expression.Literal literal_value)
            <|> ( column_reference >>| fun reference ->
                  Expression.Column reference )
        | Some '(' ->
            char '(' *> whitespace *> expression <* whitespace <* char ')'
        | _ -> fail "expected a column reference, literal, or '('"
      in
      (* A comparison atom: a term, optionally followed by a comparison
       operator and another term. The term alone is a valid expression;
       the kind check happens at resolve time, not at parse time. *)
      let comparison_expression =
        term >>= fun left ->
        let with_comparison =
          whitespace *> comparison_op >>= fun op ->
          whitespace *> term >>| fun right ->
          Expression.Compare { left; op; right }
        in
        with_comparison <|> return left
      in
      (* A [not]-prefixed expression: the prefix may stack, and binds
         tighter than [and]/[or] but looser than the comparison operators
         ([not a = 5] is [not (a = 5)]). Implemented with its own [fix] so
         the prefix recurses into another [not_expression] before falling
         through to [comparison_expression]. *)
      let not_expression =
        fix (fun not_expression ->
            keyword "not" *> whitespace *> not_expression
            >>| (fun operand -> Expression.Not operand)
            <|> comparison_expression)
      in
      (* An [and]-chain: one or more [not]-expressions joined by the [and]
       keyword, left-associative. *)
      let and_expression =
        not_expression >>= fun first ->
        many (whitespace *> keyword "and" *> whitespace *> not_expression)
        >>| fun rest ->
        List.fold_left
          (fun accumulator next -> Expression.And (accumulator, next))
          first rest
      in
      (* The top of the predicate grammar: one or more [and]-chains joined
       by the [or] keyword, left-associative. *)
      and_expression >>= fun first ->
      many (whitespace *> keyword "or" *> whitespace *> and_expression)
      >>| fun rest ->
      List.fold_left
        (fun accumulator next -> Expression.Or (accumulator, next))
        first rest)

(* The projection grammar: one column reference followed by zero or
   more [, column-reference] tails. Whitespace is flexible around the comma.
   At least one column is required; the [column_reference] before [many]
   ensures that. Leading and trailing commas are rejected because we only
   consume a comma when followed by another column reference. *)
let project_columns =
  column_reference >>= fun first_column ->
  many (whitespace *> char ',' *> whitespace *> column_reference)
  >>| fun more_columns -> first_column :: more_columns

(* A restrict pipeline step: [| restrict <predicate>]. *)
let restrict_step =
  keyword "restrict" *> whitespace *> expression
  >>| fun parsed_predicate input ->
  Ast.Restrict { input; predicate = parsed_predicate }

(* A project pipeline step: [| project <columns>]. *)
let project_step =
  keyword "project" *> whitespace *> project_columns
  >>| fun parsed_columns input ->
  Ast.Project { input; columns = parsed_columns }

(* A cross-product pipeline step: [| cross <relation>]. The right-hand side
   is a relation reference (a base table for now); nesting and
   sub-pipelines on the right are out of scope. *)
let cross_step =
  keyword "cross" *> whitespace *> identifier >>| fun right_table input ->
  Ast.CrossProduct { left = input; right = Ast.Relation_name right_table }

(* An inner-join pipeline step: [| join <relation> on <predicate>]. The
   right-hand side is a relation reference, mirroring [cross_step]; nested
   sub-pipelines on the right are out of scope. The [keyword] helper enforces
   a word break after both [join] and [on], so identifiers like [joinery]
   and [oncology] don't sneakily match. *)
let join_step =
  keyword "join" *> whitespace *> identifier >>= fun right_table ->
  whitespace *> keyword "on" *> whitespace *> expression
  >>| fun parsed_predicate input ->
  Ast.Join
    {
      left = input;
      right = Ast.Relation_name right_table;
      predicate = parsed_predicate;
    }

(* A type pipeline step: [| type]. Unary with no arguments; the keyword
   stands alone. Lowering rejects [type] applied to a type, so the
   nested form ([users | type | type]) parses fine and is caught
   downstream with a user-facing message. *)
let type_step = keyword "type" >>| fun () input -> Ast.Type { input }

(* An unqualify pipeline step: [| unqualify]. Unary with no arguments. The
   strip and collision check live in Eval; the parser just wraps the
   upstream into the AST node. *)
let unqualify_step =
  keyword "unqualify" >>| fun () input -> Ast.Unqualify { input }

(* A tables pipeline step: [| tables]. Unary with no arguments. The kind
   check (input must be a catalog value) lives in Eval; the parser just
   wraps the upstream into the AST node. *)
let tables_step = keyword "tables" >>| fun () input -> Ast.Tables { input }

(* A single pipeline step. Each branch wraps its [Ast.t] argument with
   the step's effect, so the caller can fold a list of steps
   left-to-right over the base. *)
let pipeline_step =
  whitespace *> char '|' *> whitespace
  *> (restrict_step <|> project_step <|> cross_step <|> join_step <|> type_step
    <|> unqualify_step <|> tables_step)

(* A query pipeline: a relation reference followed by zero or more
   query-operator steps, folded left-associatively. The result is an
   [Ast.t]; [pipeline_parser] below optionally wraps it in an [Insert]
   when a sink follows. *)
let query_pipeline =
  whitespace *> relation_expr >>= fun base ->
  many pipeline_step >>| fun steps ->
  List.fold_left (fun current step -> step current) base steps

(* An insert sink: [insert into <identifier>]. Returned as a function
   from the upstream relation to an [Ast.Insert] node, so the caller
   can thread the upstream pipeline through. Sits alongside
   {!create_table_seeded_sink} in the tail-position disjunction. *)
let insert_sink =
  keyword "insert" *> whitespace *> keyword "into" *> whitespace *> identifier
  >>| fun target_table source -> Ast.Insert { source; table = target_table }

(* A [create table <name>] sink in its seeded form: a value-yielding
   upstream pipeline followed by the sink builds an
   [Ast.Create_table_seeded] node carrying the upstream as the source.
   The empty form ([<type-expression> | create table <name>] →
   [Create_table_empty]) is handled by a separate dispatcher at the top
   of the pipeline grammar and never reaches this branch. *)
let create_table_seeded_sink =
  keyword "create" *> whitespace *> keyword "table" *> whitespace *> identifier
  >>| fun target_table source ->
  Ast.Create_table_seeded { table_name = target_table; source }

(* The tail-position sink disjunction. The two sinks start with distinct
   keywords ([insert] / [create]), so the disjunction commits on the
   keyword and does not backtrack across sinks. *)
let sink_step = insert_sink <|> create_table_seeded_sink

(* The [create table] sink's empty form, with a type expression at
   pipeline-source position: [<type-expression> | create table <name>]
   parses as [Ast.Create_table_empty]. A type expression is not a
   value-yielding pipeline, so this branch commits only to the [create
   table] sink -- a type expression piped into anything else (or with
   no sink at all) is a parse error. The dispatcher in {!pipeline_parser}
   tries this branch first; on failure it rewinds and falls through to
   the value-pipeline form, which carries the [create table] sink's
   seeded form alongside [insert into]. *)
let create_table_empty_form =
  whitespace *> type_expression_body >>= fun items ->
  (* Empty parens [()] are ambiguous between an empty type expression
     and an empty row literal. Fall through to the value-pipeline path
     so [() | create table foo] parses as a seeded form over an empty
     row literal, preserving the existing meaning of [()]. The
     downstream "column list is empty" check fires later, in [Eval]. *)
  if items = [] then fail "empty parens are not a type expression"
  else
    let fields, refinements = partition_type_expression_items items in
    let type_expression : Ast.type_expression = { fields; refinements } in
    whitespace *> char '|' *> whitespace *> keyword "create" *> whitespace
    *> keyword "table" *> whitespace *> identifier
    >>| fun table_name -> Ast.Create_table_empty { table_name; type_expression }

(* The pipeline grammar: a query pipeline, optionally terminated by a
   single sink step. With the sink, the result is the matching sink AST
   node wrapping the upstream pipeline; without it, the upstream pipeline
   is the whole [Ast.t]. The "at most one sink, in terminal position" rule
   is enforced by [program_parser]'s trailing [end_of_input], which
   rejects any further input after the pipeline.

   The {!create_table_empty_form} alternative is tried first so that a
   type expression on the left of the sink can be recognised before the
   value-pipeline grammar attempts to parse the same parens as a row
   literal. Both alternatives back off cleanly on inner failure thanks
   to [<|>]'s no-commit behaviour, so a value-pipeline starting with
   [(] (e.g. a row literal) reaches the second alternative once the
   type-expression branch fails. *)
let pipeline_parser =
  let value_pipeline =
    query_pipeline >>= fun upstream ->
    let with_sink =
      whitespace *> char '|' *> whitespace *> sink_step >>| fun build_sink ->
      build_sink upstream
    in
    let without_sink = return upstream in
    with_sink <|> without_sink
  in
  create_table_empty_form <|> value_pipeline

(* The DDL body grammar: the productions admitted after the [:]
   sigil has been consumed. Today's only DDL form is [:list tables]. *)
let ddl_list_tables =
  keyword "list" *> whitespace *> keyword "tables"
  *> return Ddl.Statement.List_tables

let ddl_body = ddl_list_tables

(* The top-level grammar: optional leading whitespace, then dispatch on the
   first non-whitespace character. A leading [:] introduces a DDL statement
   (the sigil is recognised only here, so a [:] inside a pipeline or
   expression is a parse error). Anything else is parsed as a relational
   pipeline. [end_of_input] at the tail enforces full consumption for both
   universes, so trailing garbage after either kind of input is rejected. *)
let program_parser =
  whitespace
  *> ( peek_char >>= function
       | Some ':' ->
           char ':' *> whitespace *> ddl_body >>| fun statement ->
           Ast.Ddl statement
       | _ -> pipeline_parser >>| fun plan -> Ast.Pipeline plan )
  <* whitespace <* end_of_input

let parse input = parse_string ~consume:All program_parser input

(* Standalone expression entry point: parse a single expression with leading
   and trailing whitespace tolerated; [end_of_input] forces full
   consumption. *)
let expression_query = whitespace *> expression <* whitespace <* end_of_input
let parse_expression input = parse_string ~consume:All expression_query input

let row_type_query =
  whitespace *> type_expression_body <* whitespace <* end_of_input
  >>= fun items ->
  match
    List.find_opt (function `Refinement _ -> true | `Field _ -> false) items
  with
  | Some _ ->
      fail
        "primary key refinement is not allowed in a row type; use a relation \
         type"
  | None ->
      let fields, refinements = partition_type_expression_items items in
      return ({ fields; refinements } : Ast.type_expression)

let relation_type_query =
  whitespace *> type_expression_body <* whitespace <* end_of_input
  >>| fun items ->
  let fields, refinements = partition_type_expression_items items in
  ({ fields; refinements } : Ast.type_expression)

let parse_row_type input = parse_string ~consume:All row_type_query input

let parse_relation_type input =
  parse_string ~consume:All relation_type_query input
