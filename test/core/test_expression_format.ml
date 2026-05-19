(** Tests for [Expression.format].

    Exercises the formatter across every node kind and every precedence-driven
    paren-insertion case. The resolver-behaviour and resolver-error tests for
    the same module live in [test_expression.ml]. *)

open Test_helpers

(* Render an [Expression.t] to a string via [Expression.format]. *)
let format_to_string expression =
  let buffer = Buffer.create 64 in
  let formatter = Format.formatter_of_buffer buffer in
  Expression.format formatter expression;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_format_column_equals_int64_literal () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:Equal
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id = 3" "id = 3" rendered

let test_format_column_equals_string_literal_quotes_string () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "name") ~op:Equal
         ~right:(expression_literal (Value.String "Alice")))
  in
  Alcotest.(check string)
    "string literal is double-quoted" "name = \"Alice\"" rendered

let test_format_column_equals_bool_literal () =
  let rendered =
    format_to_string
      (expression_compare
         ~left:(expression_column "active")
         ~op:Equal
         ~right:(expression_literal (Value.Bool true)))
  in
  Alcotest.(check string) "bool literal as keyword" "active = true" rendered

let test_format_inequality_uses_angle_brackets () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:NotEqual
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id <> 3" "id <> 3" rendered

let test_format_bare_column_renders_as_column_name () =
  let rendered = format_to_string (expression_column "active") in
  Alcotest.(check string) "bare column renders as its name" "active" rendered

let test_format_bare_literal_renders_as_literal () =
  let rendered = format_to_string (expression_literal (Value.Bool true)) in
  Alcotest.(check string)
    "bare bool literal renders as the keyword" "true" rendered

let test_format_less_than () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:Less
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id < 3" "id < 3" rendered

let test_format_less_equal () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:LessEqual
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id <= 3" "id <= 3" rendered

let test_format_greater_than () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:Greater
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id > 3" "id > 3" rendered

let test_format_greater_equal () =
  let rendered =
    format_to_string
      (expression_compare ~left:(expression_column "id") ~op:GreaterEqual
         ~right:(expression_literal (Value.Int64 3L)))
  in
  Alcotest.(check string) "id >= 3" "id >= 3" rendered

let test_format_not_of_atom () =
  let rendered =
    format_to_string (expression_not (expression_column "active"))
  in
  Alcotest.(check string) "not active" "not active" rendered

let test_format_not_of_comparison () =
  let rendered =
    format_to_string
      (expression_not
         (expression_compare ~left:(expression_column "id") ~op:Equal
            ~right:(expression_literal (Value.Int64 5L))))
  in
  Alcotest.(check string) "not id = 5" "not id = 5" rendered

let test_format_not_of_and_uses_parens () =
  (* [not (a and b)]: [and] binds looser than [not], so the [and] needs
     parens to keep the meaning when re-parsed. *)
  let rendered =
    format_to_string
      (expression_not
         (expression_and ~left:(expression_column "a")
            ~right:(expression_column "b")))
  in
  Alcotest.(check string) "not (a and b)" "not (a and b)" rendered

let test_format_stacked_not_omits_parens () =
  (* [not not active]: the inner [not] is also a [not], same precedence,
     no parens needed. *)
  let rendered =
    format_to_string
      (expression_not (expression_not (expression_column "active")))
  in
  Alcotest.(check string) "not not active" "not not active" rendered

let test_format_and_renders_with_keyword () =
  let rendered =
    format_to_string
      (expression_and
         ~left:(expression_column "active")
         ~right:
           (expression_compare ~left:(expression_column "id") ~op:Greater
              ~right:(expression_literal (Value.Int64 3L))))
  in
  Alcotest.(check string)
    "and binds looser than comparison: no parens around id > 3"
    "active and id > 3" rendered

let test_format_or_renders_with_keyword () =
  let rendered =
    format_to_string
      (expression_or
         ~left:(expression_column "active")
         ~right:(expression_column "inactive_flag"))
  in
  Alcotest.(check string)
    "active or inactive_flag" "active or inactive_flag" rendered

let test_format_and_inside_or_omits_parens () =
  (* [a or (b and c)] is the tree the parser builds for "a or b and c". The
     formatter should preserve the source form: no parens around the [and]
     because [and] binds tighter than [or]. *)
  let rendered =
    format_to_string
      (expression_or ~left:(expression_column "a")
         ~right:
           (expression_and ~left:(expression_column "b")
              ~right:(expression_column "c")))
  in
  Alcotest.(check string) "a or b and c" "a or b and c" rendered

let test_format_or_inside_and_uses_parens () =
  (* [(a or b) and c] forces parens around the [or] because [and] binds
     tighter; without parens the rendering would re-parse as
     [a or (b and c)]. *)
  let rendered =
    format_to_string
      (expression_and
         ~left:
           (expression_or ~left:(expression_column "a")
              ~right:(expression_column "b"))
         ~right:(expression_column "c"))
  in
  Alcotest.(check string) "(a or b) and c" "(a or b) and c" rendered

let test_format_and_right_associated_uses_parens () =
  (* Source [a and b and c] is parsed left-associatively, yielding
     [And (And a b) c]. The right-associated tree [And a (And b c)] is
     legal but doesn't come out of the parser; the formatter still
     handles it by parenthesising the right operand to preserve meaning. *)
  let rendered =
    format_to_string
      (expression_and ~left:(expression_column "a")
         ~right:
           (expression_and ~left:(expression_column "b")
              ~right:(expression_column "c")))
  in
  Alcotest.(check string) "a and (b and c)" "a and (b and c)" rendered

let test_format_qualified_columns_use_dot_form () =
  let rendered =
    format_to_string
      (expression_compare
         ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
         ~op:Equal
         ~right:
           (expression_qualified_column ~qualifier:"orders" ~name:"user_id"))
  in
  Alcotest.(check string)
    "qualified column references render in dotted form"
    "users.id = orders.user_id" rendered

let () =
  Alcotest.run "expression_format"
    [
      ( "format",
        [
          Alcotest.test_case "column = int64 literal" `Quick
            test_format_column_equals_int64_literal;
          Alcotest.test_case "column = string literal quotes the string" `Quick
            test_format_column_equals_string_literal_quotes_string;
          Alcotest.test_case "column = bool literal" `Quick
            test_format_column_equals_bool_literal;
          Alcotest.test_case "inequality renders with <>" `Quick
            test_format_inequality_uses_angle_brackets;
          Alcotest.test_case "qualified columns render in dotted form" `Quick
            test_format_qualified_columns_use_dot_form;
          Alcotest.test_case "bare column renders as the column name" `Quick
            test_format_bare_column_renders_as_column_name;
          Alcotest.test_case "bare literal renders as the literal" `Quick
            test_format_bare_literal_renders_as_literal;
          Alcotest.test_case "less-than renders with <" `Quick
            test_format_less_than;
          Alcotest.test_case "less-or-equal renders with <=" `Quick
            test_format_less_equal;
          Alcotest.test_case "greater-than renders with >" `Quick
            test_format_greater_than;
          Alcotest.test_case "greater-or-equal renders with >=" `Quick
            test_format_greater_equal;
          Alcotest.test_case "and renders with the keyword" `Quick
            test_format_and_renders_with_keyword;
          Alcotest.test_case "or renders with the keyword" `Quick
            test_format_or_renders_with_keyword;
          Alcotest.test_case
            "and inside or omits parens because and binds tighter" `Quick
            test_format_and_inside_or_omits_parens;
          Alcotest.test_case
            "or inside and is parenthesised because and binds tighter" `Quick
            test_format_or_inside_and_uses_parens;
          Alcotest.test_case
            "right-associated and is parenthesised to preserve meaning" `Quick
            test_format_and_right_associated_uses_parens;
          Alcotest.test_case "not renders as 'not' followed by an atom" `Quick
            test_format_not_of_atom;
          Alcotest.test_case
            "not of a comparison binds the comparison tighter (no parens)"
            `Quick test_format_not_of_comparison;
          Alcotest.test_case "not of an and-expression parenthesises the and"
            `Quick test_format_not_of_and_uses_parens;
          Alcotest.test_case "stacked not omits parens" `Quick
            test_format_stacked_not_omits_parens;
        ] );
    ]
