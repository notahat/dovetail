open Angstrom
module StringSet = Set.Make (String)
module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
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

let relation_name = identifier >>| fun name -> Ast.Relation_name name

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
  | Some number -> return (Value.Int64 number)
  | None -> fail "int64 literal out of range"

(* A bool literal. The [keyword] helper enforces a word break after the
   literal text, so [trueish] doesn't sneakily match [true]. *)
let bool_literal =
  keyword "true" *> return (Value.Bool true)
  <|> keyword "false" *> return (Value.Bool false)

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
  Value.String (Buffer.contents buffer)

(* A single literal value in a relation literal's value position: int,
   string, or bool. The dispatch on the leading character matches the
   [term] parser inside [expression]; bare identifiers (column references)
   are deliberately not accepted here -- the design doc reserves the
   value position for expressions, but in insert context columns have no
   row to resolve against, so until a future slice introduces an
   expression IR for the value position the surface form is "literal." *)
let literal_value =
  peek_char >>= function
  | Some '"' -> string_literal
  | Some '-' -> int64_literal
  | Some character when is_digit character -> int64_literal
  | Some character when is_letter character -> bool_literal
  | _ -> fail "expected a literal value (number, string, or bool)"

(* One pair parsed inside a relation literal's braces. [column_key] is the
   key text as written (bare [id] or dotted [users.id]); [key_is_qualified]
   records the dotted-form flag so post-pass validation can name it in the
   error. A record rather than a 3-tuple so the eventual addition of, say,
   a source-span field doesn't force every destructure site to change. *)
type literal_pair = {
  column_key : string;
  value : Value.t;
  key_is_qualified : bool;
}

(* A single key-value pair inside a relation literal: [identifier : value].
   Whitespace around the colon is tolerated. The key grammar accepts both
   bare and qualified forms ([id] and [users.id]); the surface language
   forbids qualified keys, but rejecting them here would happen inside an
   angstrom [many], which backtracks on inner-parser failure and would
   discard the useful message. Instead the pair returns the full key text
   plus a flag, and {!relation_literal} validates after [many] has run --
   the same shape as the duplicate-column check below. *)
let relation_literal_pair =
  identifier >>= fun first_segment ->
  ( peek_char >>= function
    | Some '.' ->
        char '.' *> identifier >>| fun second_segment ->
        (first_segment ^ "." ^ second_segment, true)
    | _ -> return (first_segment, false) )
  >>= fun (column_key, key_is_qualified) ->
  whitespace *> char ':' *> whitespace *> literal_value >>| fun value ->
  { column_key; value; key_is_qualified }

(* One or more pairs separated by commas, with whitespace tolerated around
   commas and an optional trailing comma. The list is non-empty: the empty
   literal [{}] is rejected because we require at least one pair. *)
let relation_literal_pairs =
  relation_literal_pair >>= fun first_pair ->
  many (whitespace *> char ',' *> whitespace *> relation_literal_pair)
  >>= fun more_pairs ->
  whitespace *> option false (char ',' *> return true) >>| fun _trailing ->
  first_pair :: more_pairs

(* Raise a parse error if any pair carries a qualified key. The error
   names the first offender in full ([users.id], not just [users]) so the
   user can find what they typed. Runs after [many] has gathered the
   pairs, sidestepping angstrom's backtracking on inner-parser failure. *)
let check_for_qualified_keys pairs =
  match List.find_opt (fun pair -> pair.key_is_qualified) pairs with
  | None -> return ()
  | Some offender ->
      fail
        (Printf.sprintf
           "qualified column key %S in relation literal: only bare column \
            names are allowed"
           offender.column_key)

(* Raise a parse error if [pairs] contains the same column name twice. The
   error names the first duplicate so the user can find it. Walks [pairs]
   left to right accumulating a [StringSet] of seen names; the
   accumulator-passing form replaces the prior [Hashtbl] mutation. *)
let check_for_duplicate_columns pairs =
  let rec walk seen = function
    | [] -> return ()
    | pair :: _ when StringSet.mem pair.column_key seen ->
        fail
          (Printf.sprintf "duplicate column %S in relation literal"
             pair.column_key)
    | pair :: rest -> walk (StringSet.add pair.column_key seen) rest
  in
  walk StringSet.empty pairs

(* A relation literal: [{column: value, column: value, ...}]. Single-row
   named-pair form only -- the multi-row literal grammar is a separate
   production deferred to a future slice. *)
let relation_literal =
  char '{' *> whitespace *> relation_literal_pairs <* whitespace <* char '}'
  >>= fun pairs ->
  check_for_qualified_keys pairs >>= fun () ->
  check_for_duplicate_columns pairs >>| fun () ->
  let columns = List.map (fun pair -> pair.column_key) pairs in
  let values = List.map (fun pair -> pair.value) pairs in
  Ast.RelationLiteral { columns; rows = [ values ] }

(* The leading position of a pipeline: either a bare table reference or a
   relation literal. Disjoint on the first character ([{] vs a letter), so
   no backtracking is required. *)
let relation_expr =
  peek_char >>= function Some '{' -> relation_literal | _ -> relation_name

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

(* A column reference: either a bare identifier (unqualified) or two
   identifiers separated by a dot with no whitespace around it (qualified).
   The no-whitespace rule on the dot keeps the syntax disjoint from a future
   floating-point literal grammar. *)
let column_reference =
  identifier >>= fun first ->
  peek_char >>= function
  | Some '.' ->
      char '.' *> identifier >>| fun second ->
      ({ qualifier = Some first; name = second } : Schema.column_reference)
  | _ -> return ({ qualifier = None; name = first } : Schema.column_reference)

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

(* The slice-3 projection grammar: one column reference followed by zero or
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
   sub-pipelines on the right are out of scope for slice 4. *)
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

(* A single pipeline step. Each branch wraps its [Ast.t] argument with
   the step's effect, so the caller can fold a list of steps
   left-to-right over the base. *)
let pipeline_step =
  whitespace *> char '|' *> whitespace
  *> (restrict_step <|> project_step <|> cross_step <|> join_step)

(* A query pipeline: a relation reference followed by zero or more
   query-operator steps, folded left-associatively. The result is an
   [Ast.t]; the outer [plan] wrapper is applied by [plan_parser] below
   depending on whether a sink follows. *)
let query_pipeline =
  whitespace *> relation_expr >>= fun base ->
  many pipeline_step >>| fun steps ->
  List.fold_left (fun current step -> step current) base steps

(* An insert sink: [insert into <identifier>]. Returned as a function
   from the upstream relation to an [Ast.mutation], so the caller can
   thread the upstream pipeline through. Currently the only sink the
   grammar admits; future sinks (delete, ...) sit alongside this one
   inside a [sink_step] disjunction. *)
let insert_sink =
  keyword "insert" *> whitespace *> keyword "into" *> whitespace *> identifier
  >>| fun target_table source -> Ast.Insert { source; table = target_table }

(* The slice-11 pipeline grammar: a query pipeline, optionally terminated
   by a single sink step. A sink lifts the result into [Ast.Mutation];
   absent a sink the result is an [Ast.Query]. The "at most one sink, in
   terminal position" rule is enforced by [program_parser]'s trailing
   [end_of_input], which rejects any further input after the pipeline. *)
let pipeline_parser =
  query_pipeline >>= fun upstream ->
  let with_sink =
    whitespace *> char '|' *> whitespace *> insert_sink >>| fun build_sink ->
    Ast.Mutation (build_sink upstream)
  in
  let without_sink = return (Ast.Query upstream) in
  with_sink <|> without_sink

(* The slice-12 DDL body grammar: the productions admitted after the [:]
   sigil has been consumed. The disjunction relies on [<|>]'s backtracking
   on inner failure: each branch starts with a distinct keyword
   ([list]/[drop]), so a failed first branch rewinds to the start of the
   body and the second branch tries from the same position. Future
   productions ([describe], [create]) slot in alongside these. *)
let ddl_list_tables =
  keyword "list" *> whitespace *> keyword "tables"
  *> return Ddl.Statement.List_tables

let ddl_drop_table =
  keyword "drop" *> whitespace *> keyword "table" *> whitespace *> identifier
  >>| fun table_name -> Ddl.Statement.Drop_table { table_name }

let ddl_describe =
  keyword "describe" *> whitespace *> identifier >>| fun table_name ->
  Ddl.Statement.Describe { table_name }

let ddl_body = ddl_list_tables <|> ddl_drop_table <|> ddl_describe

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
