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

(* A signed int64 literal: optional leading minus, then one or more digits.
   Fails (rather than producing a wrong value) on inputs that overflow
   int64, since [Int64.of_string_opt] handles range checking for us. *)
let int64_literal =
  option "" (string "-") >>= fun sign ->
  take_while1 is_digit >>= fun digits ->
  match Int64.of_string_opt (sign ^ digits) with
  | Some number -> return (Value.Int64 number)
  | None -> fail "int64 literal out of range"

(* A bool literal. Requires a non-identifier character (or end of input)
   to follow, so [trueish] doesn't sneakily match [true]. *)
let bool_literal =
  let followed_by_word_break =
    peek_char >>= function
    | None -> return ()
    | Some character when is_identifier_continuation character ->
        fail "expected end of bool literal"
    | Some _ -> return ()
  in
  string "true" *> followed_by_word_break *> return (Value.Bool true)
  <|> string "false" *> followed_by_word_break *> return (Value.Bool false)

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

(* Dispatch to the right literal parser by lookahead, rather than relying
   on [<|>] to backtrack between alternatives that may have committed. *)
let literal =
  peek_char >>= function
  | Some '"' -> string_literal
  | Some 't' | Some 'f' -> bool_literal
  | Some '-' -> int64_literal
  | Some character when is_digit character -> int64_literal
  | _ -> fail "expected a literal"

(* The two slice-2 comparison operators. Dispatched by lookahead so the
   choice between [=] and [<>] is unambiguous and doesn't depend on
   [<|>] backtracking behaviour. *)
let comparison_op =
  peek_char >>= function
  | Some '=' -> char '=' *> return Predicate.Equal
  | Some '<' -> string "<>" *> return Predicate.NotEqual
  | _ -> fail "expected '=' or '<>'"

(* The slice-2 predicate grammar: [<column-name> <op> <literal>]. The
   right-hand side is a literal, never an identifier; that's the
   strictness the slice plan calls for. *)
let predicate =
  identifier >>= fun column_name ->
  whitespace *> comparison_op >>= fun op ->
  whitespace *> literal >>| fun literal_value ->
  Predicate.Compare { column_name; op; literal = literal_value }

(* The complete slice-1 grammar: optional whitespace, an identifier, optional
   whitespace, end of input. [end_of_input] is what forces the parser to
   reject trailing tokens like "users orders". *)
let query = whitespace *> relation_name <* whitespace <* end_of_input
let parse input = parse_string ~consume:All query input

(* Standalone predicate entry point: leading/trailing whitespace tolerated,
   end_of_input forces full consumption. *)
let predicate_query = whitespace *> predicate <* whitespace <* end_of_input
let parse_predicate input = parse_string ~consume:All predicate_query input
