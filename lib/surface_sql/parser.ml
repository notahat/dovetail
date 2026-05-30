open Angstrom

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

(* A [SELECT * FROM <table>] statement. The [*] select list and the bare
   table name are the only shapes today; a column list and a [WHERE] clause
   arrive in later slices. *)
let select_statement =
  keyword "select" *> whitespace *> char '*' *> whitespace *> keyword "from"
  *> whitespace *> identifier
  >>| fun from -> Ast.Select { select_list = Ast.All; from }

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
