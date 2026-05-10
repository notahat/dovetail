open Angstrom

type error = string

let is_letter character =
  (character >= 'a' && character <= 'z')
  || (character >= 'A' && character <= 'Z')

let is_identifier_continuation character =
  is_letter character
  || (character >= '0' && character <= '9')
  || character = '_'

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

(* The complete slice-1 grammar: optional whitespace, an identifier, optional
   whitespace, end of input. [end_of_input] is what forces the parser to
   reject trailing tokens like "users orders". *)
let query = whitespace *> relation_name <* whitespace <* end_of_input
let parse input = parse_string ~consume:All query input
