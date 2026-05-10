open Angstrom

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

(* The two slice-2 comparison operators. Dispatched by lookahead so the
   choice between [=] and [<>] is unambiguous and doesn't depend on
   [<|>] backtracking behaviour. *)
let comparison_op =
  peek_char >>= function
  | Some '=' -> char '=' *> return Predicate.Equal
  | Some '<' -> string "<>" *> return Predicate.NotEqual
  | _ -> fail "expected '=' or '<>'"

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

(* A single side of a comparison: a literal or a column reference. The bool
   literals [true] and [false] are spelled with letters that would otherwise
   start an identifier, so when the input starts with a letter we try the
   bool literal first and fall back to the column-reference parser. The bool
   parser uses [keyword], which requires a word break after the literal
   text, so [trueish] cleanly falls through to the column-reference branch. *)
let term =
  peek_char >>= function
  | Some '"' ->
      string_literal >>| fun literal_value -> Predicate.Literal literal_value
  | Some '-' ->
      int64_literal >>| fun literal_value -> Predicate.Literal literal_value
  | Some character when is_digit character ->
      int64_literal >>| fun literal_value -> Predicate.Literal literal_value
  | Some character when is_letter character ->
      bool_literal
      >>| (fun literal_value -> Predicate.Literal literal_value)
      <|> (column_reference >>| fun reference -> Predicate.Column reference)
  | _ -> fail "expected a column reference or literal"

(* The predicate grammar: [<term> <op> <term>], where each term is either a
   column reference or a literal. Slice 2 only allowed a literal on the
   right; slice 4 step 2 lifts that restriction so column-vs-column
   comparisons (used to match across cross-product inputs) parse. *)
let predicate =
  term >>= fun left ->
  whitespace *> comparison_op >>= fun op ->
  whitespace *> term >>| fun right -> Predicate.Compare { left; op; right }

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
  keyword "restrict" *> whitespace *> predicate
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
  whitespace *> keyword "on" *> whitespace *> predicate
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

(* The slice-2 grammar: a relation reference followed by zero or more
   pipeline steps, surrounded by optional whitespace. Each step wraps the
   running AST in a [Restrict], left-associatively. *)
let query =
  whitespace *> relation_name >>= fun base ->
  many pipeline_step >>= fun steps ->
  whitespace *> end_of_input
  *> return (List.fold_left (fun current step -> step current) base steps)

let parse input = parse_string ~consume:All query input

(* Standalone predicate entry point: leading/trailing whitespace tolerated,
   end_of_input forces full consumption. *)
let predicate_query = whitespace *> predicate <* whitespace <* end_of_input
let parse_predicate input = parse_string ~consume:All predicate_query input
