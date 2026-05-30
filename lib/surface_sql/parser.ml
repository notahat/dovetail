open Angstrom
module Scalar = Dovetail_core.Scalar

type error = string

let is_letter character =
  (character >= 'a' && character <= 'z')
  || (character >= 'A' && character <= 'Z')

let is_digit character = character >= '0' && character <= '9'

let is_identifier_continuation character =
  is_letter character || is_digit character || character = '_'

let is_whitespace = function ' ' | '\t' | '\n' | '\r' -> true | _ -> false

(* Consume zero or more whitespace characters. Succeeds even when no
   whitespace is present, so it can sit between tokens as an optional
   separator. *)
let whitespace = skip_while is_whitespace

(* An identifier: one letter, then any number of letters, digits, or
   underscores. Returned verbatim -- identifiers are case-sensitive, matched
   byte-for-byte against the catalog. *)
let identifier =
  satisfy is_letter >>= fun first_character ->
  take_while is_identifier_continuation >>| fun continuation ->
  String.make 1 first_character ^ continuation

(* Match a single character case-insensitively. Used to assemble the
   case-insensitive keyword matcher; SQL keywords ignore case
   ([SELECT] = [select] = [SeLeCt]). *)
let character_ignoring_case expected =
  satisfy (fun character ->
      Char.lowercase_ascii character = Char.lowercase_ascii expected)
  *> return ()

(* Match a keyword case-insensitively, then require a word break (a
   non-identifier character or end of input) afterwards. [name] is the
   canonical lowercase spelling. The word break is what stops [keyword "from"]
   from matching the leading [from] of an identifier like [fromage]. *)
let keyword name =
  String.fold_left
    (fun matched_so_far character ->
      matched_so_far *> character_ignoring_case character)
    (return ()) name
  *> ( peek_char >>= function
       | None -> return ()
       | Some character when not (is_identifier_continuation character) ->
           return ()
       | Some _ -> fail (Printf.sprintf "expected end of keyword %S" name) )

(* A signed int64 literal: optional leading minus, then one or more digits.
   Fails (rather than producing a wrong value) on inputs that overflow int64,
   since [Int64.of_string_opt] handles range checking. *)
let int64_literal =
  option "" (string "-") >>= fun sign ->
  take_while1 is_digit >>= fun digits ->
  match Int64.of_string_opt (sign ^ digits) with
  | Some number -> return (Scalar.Int64 number)
  | None -> fail "int64 literal out of range"

(* A bool literal. [TRUE] and [FALSE] are keywords, so they are matched
   case-insensitively and require a word break afterwards -- [trueish] is a
   column reference, not the [TRUE] literal followed by [ish]. *)
let bool_literal =
  keyword "true" *> return (Scalar.Bool true)
  <|> keyword "false" *> return (Scalar.Bool false)

(* A single-quoted string literal. SQL's quote convention is single quotes;
   the double-quoted form is not a string here. Embedded quotes (SQL's ['']
   doubling) are not yet handled, so a string containing a quote is a parse
   error rather than silently mis-parsed. *)
let string_literal =
  char '\'' *> take_while (fun character -> character <> '\'') <* char '\''
  >>| fun text -> Scalar.String text

(* A bare column reference: a single identifier, always unqualified. The dotted
   [qualifier.name] form is deferred to the joins slice; a leftover [.] after
   the identifier is rejected by the statement's [end_of_input]. *)
let column_reference =
  identifier >>| fun name -> ({ qualifier = None; name } : Ast.column_reference)

(* The six comparison operators. Dispatched by lookahead on the leading
   character, with a second lookahead disambiguating [<]/[<=]/[<>] and
   [>]/[>=]. Both [<>] and [!=] produce [NotEqual]. *)
let comparison_op =
  peek_char >>= function
  | Some '=' -> char '=' *> return Ast.Equal
  | Some '!' -> char '!' *> char '=' *> return Ast.NotEqual
  | Some '<' -> (
      char '<' *> peek_char >>= function
      | Some '>' -> char '>' *> return Ast.NotEqual
      | Some '=' -> char '=' *> return Ast.LessEqual
      | _ -> return Ast.Less)
  | Some '>' -> (
      char '>' *> peek_char >>= function
      | Some '=' -> char '=' *> return Ast.GreaterEqual
      | _ -> return Ast.Greater)
  | _ -> fail "expected a comparison operator"

(* The predicate grammar, built bottom-up inside [fix] so an atom can recurse
   into the full expression via parens. From loosest to tightest precedence:
   [or], [and], [not], comparison, then the atomic [term]. The five tiers live
   as nested [let]s inside one [fix] so the precedence chain reads top-to-bottom
   in one place, matching the relational-algebra surface's expression parser.
   The 35-line guideline is treated as a deliberate exception here for that
   parity. *)
let expression =
  fix (fun expression ->
      (* A single atom: a literal, a bare column reference, or a parenthesised
         sub-expression. [TRUE] / [FALSE] start with a letter that would
         otherwise begin an identifier, so on a leading letter the bool literal
         is tried first, falling back to a column reference. *)
      let term =
        peek_char >>= function
        | Some '\'' ->
            string_literal >>| fun literal_value -> Ast.Literal literal_value
        | Some '-' ->
            int64_literal >>| fun literal_value -> Ast.Literal literal_value
        | Some character when is_digit character ->
            int64_literal >>| fun literal_value -> Ast.Literal literal_value
        | Some character when is_letter character ->
            bool_literal
            >>| (fun literal_value -> Ast.Literal literal_value)
            <|> (column_reference >>| fun reference -> Ast.Column reference)
        | Some '(' ->
            char '(' *> whitespace *> expression <* whitespace <* char ')'
        | _ -> fail "expected a column reference, literal, or '('"
      in
      (* A comparison: a term, optionally followed by a comparison operator and
         a second term. The term alone is a valid predicate atom; the kind
         check happens at the logical layer, not at parse time. *)
      let comparison_expression =
        term >>= fun left ->
        let with_comparison =
          whitespace *> comparison_op >>= fun op ->
          whitespace *> term >>| fun right -> Ast.Compare { left; op; right }
        in
        with_comparison <|> return left
      in
      (* A [NOT]-prefixed expression: the prefix may stack and binds tighter
         than [AND] / [OR] but looser than comparison ([NOT a = 5] is
         [NOT (a = 5)]). *)
      let not_expression =
        fix (fun not_expression ->
            keyword "not" *> whitespace *> not_expression
            >>| (fun operand -> Ast.Not operand)
            <|> comparison_expression)
      in
      (* An [AND]-chain: one or more [NOT]-expressions joined by [AND],
         left-associative. *)
      let and_expression =
        not_expression >>= fun first ->
        many (whitespace *> keyword "and" *> whitespace *> not_expression)
        >>| fun rest ->
        List.fold_left
          (fun accumulator next -> Ast.And (accumulator, next))
          first rest
      in
      (* The top of the predicate grammar: one or more [AND]-chains joined by
         [OR], left-associative. *)
      and_expression >>= fun first ->
      many (whitespace *> keyword "or" *> whitespace *> and_expression)
      >>| fun rest ->
      List.fold_left
        (fun accumulator next -> Ast.Or (accumulator, next))
        first rest)

(* An optional [WHERE <predicate>] clause. Returns [Some predicate] when
   present, [None] otherwise; the leading whitespace and [where] keyword are
   consumed only on a match, so [option] cleanly rewinds when no clause
   follows. *)
let where_clause =
  option None
    ( whitespace *> keyword "where" *> whitespace *> expression
    >>| fun predicate -> Some predicate )

(* The select list: either [*] (every column) or a non-empty comma-separated
   list of bare column references, in the order written. The leading [*] is
   tried first; on a non-[*] input the column list is parsed, requiring at
   least one column and only consuming a comma when another column follows, so
   leading and trailing commas are rejected. *)
let select_list =
  char '*' *> return Ast.All
  <|> ( column_reference >>= fun first_column ->
        many (whitespace *> char ',' *> whitespace *> column_reference)
        >>| fun more_columns -> Ast.Columns (first_column :: more_columns) )

(* A [SELECT <select-list> FROM <table> [WHERE <predicate>]] statement. The
   bare table name is the only FROM shape today; joins and qualified names
   arrive in a later slice. *)
let select_statement =
  keyword "select" *> whitespace *> select_list >>= fun select_list ->
  whitespace *> keyword "from" *> whitespace *> identifier >>= fun from ->
  where_clause >>| fun where -> Ast.Select { select_list; from; where }

(* The top-level grammar: optional leading whitespace, one statement, an
   optional trailing semicolon, then end of input. [end_of_input] forces full
   consumption, so trailing junk -- including a second statement after the
   semicolon -- is rejected. *)
let statement =
  whitespace *> select_statement
  <* whitespace
  <* option () (char ';' *> return ())
  <* whitespace <* end_of_input

let parse input = parse_string ~consume:All statement input
