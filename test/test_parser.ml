(** Tests for [Parser]. *)

open Dovetail
open Test_helpers

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

let predicate_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<predicate>")) ( = )

let parses input expected_ast =
  match Parser.parse input with
  | Ok ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses" input)
        expected_ast ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

let parses_predicate input expected =
  match Parser.parse_predicate input with
  | Ok predicate ->
      Alcotest.(check predicate_testable)
        (Printf.sprintf "%S parses" input)
        expected predicate
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects_predicate input =
  match Parser.parse_predicate input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

let test_parses_bare_identifier () = parses "users" (Ast.Relation_name "users")

let test_tolerates_leading_whitespace () =
  parses "   users" (Ast.Relation_name "users")

let test_tolerates_trailing_whitespace () =
  parses "users   " (Ast.Relation_name "users")

let test_tolerates_surrounding_whitespace_with_tabs_and_newlines () =
  parses "\n\tusers\n" (Ast.Relation_name "users")

let test_accepts_digits_and_underscores_after_first_character () =
  parses "users_2" (Ast.Relation_name "users_2")

let test_rejects_empty_input () = rejects ""
let test_rejects_whitespace_only_input () = rejects "   "
let test_rejects_identifier_starting_with_digit () = rejects "1users"
let test_rejects_identifier_starting_with_underscore () = rejects "_users"

let test_rejects_two_identifiers () =
  (* Multiple tokens are out of scope for slice 1's grammar; the parser must
     refuse them now so we don't accidentally start accepting them later. *)
  rejects "users orders"

(* Local shorthand to keep test bodies short under the slice-4 predicate
   shape. *)
let predicate_column name : Predicate.term = Column { qualifier = None; name }

let predicate_qualified_column ~qualifier ~name : Predicate.term =
  Column { qualifier = Some qualifier; name }

let predicate_literal value : Predicate.term = Literal value

let predicate_compare ~left ~op ~right : Predicate.t =
  Compare { left; op; right }

let test_predicate_int64_equality () =
  parses_predicate "id = 3"
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_predicate_negative_int64 () =
  parses_predicate "id = -1"
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 (-1L))))

let test_predicate_string_equality () =
  parses_predicate "name = \"Alice\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "Alice")))

let test_predicate_string_with_escaped_quotes () =
  parses_predicate "name = \"with \\\"quotes\\\"\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "with \"quotes\"")))

let test_predicate_string_with_escaped_backslash () =
  parses_predicate "name = \"a\\\\b\""
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_literal (Value.String "a\\b")))

let test_predicate_bool_true () =
  parses_predicate "active = true"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_literal (Value.Bool true)))

let test_predicate_bool_false () =
  parses_predicate "active = false"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_literal (Value.Bool false)))

let test_predicate_inequality () =
  parses_predicate "id <> 3"
    (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
       ~right:(predicate_literal (Value.Int64 3L)))

let test_predicate_tolerates_extra_whitespace () =
  parses_predicate "  id   =   3  "
    (predicate_compare ~left:(predicate_column "id") ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_predicate_literal_on_the_left () =
  (* Slice 4 step 2 lifts the slice-2 restriction that the right side must
     be a literal -- either side can now be a column or a literal. *)
  parses_predicate "3 = id"
    (predicate_compare
       ~left:(predicate_literal (Value.Int64 3L))
       ~op:Equal ~right:(predicate_column "id"))

let test_predicate_column_equals_column () =
  parses_predicate "name = email"
    (predicate_compare ~left:(predicate_column "name") ~op:Equal
       ~right:(predicate_column "email"))

let test_predicate_column_inequality_column () =
  parses_predicate "id <> user_id"
    (predicate_compare ~left:(predicate_column "id") ~op:NotEqual
       ~right:(predicate_column "user_id"))

let test_predicate_qualified_column_against_literal () =
  parses_predicate "users.id = 3"
    (predicate_compare
       ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
       ~op:Equal
       ~right:(predicate_literal (Value.Int64 3L)))

let test_predicate_qualified_column_against_qualified_column () =
  parses_predicate "users.id = orders.user_id"
    (predicate_compare
       ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
       ~op:Equal
       ~right:(predicate_qualified_column ~qualifier:"orders" ~name:"user_id"))

let test_predicate_rejects_dot_with_whitespace () =
  (* The dot in a qualified reference must have no whitespace around it, so
     the syntax stays disjoint from a future floating-point literal. *)
  rejects_predicate "users .id = 3";
  rejects_predicate "users. id = 3"

let test_predicate_rejects_empty_input () = rejects_predicate ""
let test_predicate_rejects_whitespace_only_input () = rejects_predicate "   "
let test_predicate_rejects_missing_operator () = rejects_predicate "id 3"

let test_predicate_rejects_unterminated_string () =
  rejects_predicate "name = \"Alice"

let test_predicate_rejects_unrecognised_escape () =
  rejects_predicate "name = \"\\n\""

let test_predicate_keyword_prefix_is_an_identifier () =
  (* [trueish] is not the bool literal [true] with [ish] left over -- it is
     a single identifier, and so parses as a column reference on the
     right-hand side of the comparison. *)
  parses_predicate "active = trueish"
    (predicate_compare
       ~left:(predicate_column "active")
       ~op:Equal
       ~right:(predicate_column "trueish"))

let test_predicate_rejects_trailing_garbage () =
  rejects_predicate "id = 3 garbage"

let id_equals_three : Predicate.t =
  Compare
    {
      left = Column { qualifier = None; name = "id" };
      op = Equal;
      right = Literal (Value.Int64 3L);
    }

let active_equals_true : Predicate.t =
  Compare
    {
      left = Column { qualifier = None; name = "active" };
      op = Equal;
      right = Literal (Value.Bool true);
    }

let test_pipeline_parses_single_restrict () =
  parses "users | restrict id = 3"
    (Ast.Restrict
       { input = Ast.Relation_name "users"; predicate = id_equals_three })

let test_pipeline_parses_two_restrict_steps_left_associative () =
  parses "users | restrict id = 3 | restrict active = true"
    (Ast.Restrict
       {
         input =
           Ast.Restrict
             { input = Ast.Relation_name "users"; predicate = id_equals_three };
         predicate = active_equals_true;
       })

let test_pipeline_tolerates_extra_whitespace_around_pipe () =
  parses "users    |    restrict id = 3"
    (Ast.Restrict
       { input = Ast.Relation_name "users"; predicate = id_equals_three })

let test_pipeline_rejects_leading_pipe () = rejects "| users"
let test_pipeline_rejects_trailing_pipe () = rejects "users |"

let test_pipeline_rejects_restrict_without_predicate () =
  rejects "users | restrict"

let test_pipeline_rejects_restrict_without_input () = rejects "restrict id = 3"
let test_pipeline_rejects_unknown_keyword () = rejects "users | filter id = 3"

let test_pipeline_yields_fixture_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "five rows from parsed query" expected_users_rows rows)

let test_pipeline_restrict_yields_filtered_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id = 3" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check tuple_list_testable)
        "Carol's row from parsed restrict"
        [ List.nth expected_users_rows 2 ]
        rows)

let users_relation = Ast.Relation_name "users"

(* Local shorthand for the column-reference shape that {!Projection.t} now
   carries. *)
let project_column name : Schema.column_reference = { qualifier = None; name }

let project_qualified_column ~qualifier ~name : Schema.column_reference =
  { qualifier = Some qualifier; name }

let test_pipeline_parses_single_column_project () =
  parses "users | project name"
    (Ast.Project { input = users_relation; columns = [ project_column "name" ] })

let test_pipeline_parses_multi_column_project () =
  parses "users | project name, email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ project_column "name"; project_column "email" ];
       })

let test_pipeline_parses_project_without_spaces_around_comma () =
  parses "users | project name,email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ project_column "name"; project_column "email" ];
       })

let test_pipeline_parses_project_with_space_before_comma () =
  parses "users | project name ,email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ project_column "name"; project_column "email" ];
       })

let test_pipeline_parses_project_reordering_columns () =
  parses "users | project email, id"
    (Ast.Project
       {
         input = users_relation;
         columns = [ project_column "email"; project_column "id" ];
       })

let test_pipeline_parses_chained_project () =
  parses "users | project name | project email"
    (Ast.Project
       {
         input =
           Ast.Project
             { input = users_relation; columns = [ project_column "name" ] };
         columns = [ project_column "email" ];
       })

let test_pipeline_parses_restrict_then_project () =
  parses "users | restrict id = 3 | project name, email"
    (Ast.Project
       {
         input =
           Ast.Restrict { input = users_relation; predicate = id_equals_three };
         columns = [ project_column "name"; project_column "email" ];
       })

let test_pipeline_parses_project_with_qualified_columns () =
  parses "users | project users.name, users.email"
    (Ast.Project
       {
         input = users_relation;
         columns =
           [
             project_qualified_column ~qualifier:"users" ~name:"name";
             project_qualified_column ~qualifier:"users" ~name:"email";
           ];
       })

let test_pipeline_rejects_project_without_columns () = rejects "users | project"

let test_pipeline_rejects_project_with_leading_comma () =
  rejects "users | project ,name"

let test_pipeline_rejects_project_with_trailing_comma () =
  rejects "users | project name,"

let test_pipeline_rejects_project_missing_comma () =
  rejects "users | project name email"

let orders_relation = Ast.Relation_name "orders"

let test_pipeline_parses_cross_product () =
  parses "users | cross orders"
    (Ast.CrossProduct { left = users_relation; right = orders_relation })

let test_pipeline_parses_cross_product_then_restrict () =
  parses "users | cross orders | restrict users.id = orders.user_id"
    (Ast.Restrict
       {
         input =
           Ast.CrossProduct { left = users_relation; right = orders_relation };
         predicate =
           Compare
             {
               left = Column { qualifier = Some "users"; name = "id" };
               op = Equal;
               right = Column { qualifier = Some "orders"; name = "user_id" };
             };
       })

let test_pipeline_rejects_cross_without_relation () = rejects "users | cross"

let test_pipeline_keyword_prefix_is_a_relation_name () =
  (* [crossroads] starts with "cross" but is a single identifier, so it
     parses as a relation reference rather than a malformed cross step. *)
  parses "users | cross crossroads"
    (Ast.CrossProduct
       { left = users_relation; right = Ast.Relation_name "crossroads" })

let test_pipeline_cross_yields_thirty_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | cross orders" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check int)
        "5 users x 6 orders = 30 rows from parsed cross" 30 (List.length rows))

let test_pipeline_cross_then_restrict_yields_matched_pairs () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match
          Parser.parse
            "users | cross orders | restrict users.id = orders.user_id"
        with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      Alcotest.(check int)
        "six matched (user, order) pairs from parsed pipeline" 6
        (List.length rows))

let test_pipeline_cross_then_ambiguous_restrict_raises () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | cross orders | restrict id = 3" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Alcotest.check_raises "ambiguous unqualified column"
        (Failure
           "Predicate.resolve: ambiguous column reference \"id\": matches \
            \"users.id\" and \"orders.id\"") (fun () ->
          let _ = Eval.eval environment transaction physical in
          ()))

let test_pipeline_project_yields_projected_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | project name, email" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      let relation = Eval.eval environment transaction physical in
      let rows = List.of_seq relation.tuples in
      let expected =
        [
          [| Value.String "Alice"; Value.String "alice@example.com" |];
          [| Value.String "Bob"; Value.String "bob@example.com" |];
          [| Value.String "Carol"; Value.String "carol@example.com" |];
          [| Value.String "Dave"; Value.String "dave@example.com" |];
          [| Value.String "Eve"; Value.String "eve@example.com" |];
        ]
      in
      Alcotest.(check tuple_list_testable)
        "five projected rows from parsed project" expected rows)

let () =
  Alcotest.run "parser"
    [
      ( "identifier",
        [
          Alcotest.test_case "parses a bare identifier" `Quick
            test_parses_bare_identifier;
          Alcotest.test_case "tolerates leading whitespace" `Quick
            test_tolerates_leading_whitespace;
          Alcotest.test_case "tolerates trailing whitespace" `Quick
            test_tolerates_trailing_whitespace;
          Alcotest.test_case
            "tolerates surrounding whitespace with tabs and newlines" `Quick
            test_tolerates_surrounding_whitespace_with_tabs_and_newlines;
          Alcotest.test_case "accepts digits and underscores after the first"
            `Quick test_accepts_digits_and_underscores_after_first_character;
        ] );
      ( "rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_rejects_whitespace_only_input;
          Alcotest.test_case "rejects identifier starting with a digit" `Quick
            test_rejects_identifier_starting_with_digit;
          Alcotest.test_case "rejects identifier starting with an underscore"
            `Quick test_rejects_identifier_starting_with_underscore;
          Alcotest.test_case "rejects two identifiers" `Quick
            test_rejects_two_identifiers;
        ] );
      ( "predicate literals and operators",
        [
          Alcotest.test_case "id = 3" `Quick test_predicate_int64_equality;
          Alcotest.test_case "id = -1 (negative int64)" `Quick
            test_predicate_negative_int64;
          Alcotest.test_case "name = \"Alice\"" `Quick
            test_predicate_string_equality;
          Alcotest.test_case "string literal with escaped quotes" `Quick
            test_predicate_string_with_escaped_quotes;
          Alcotest.test_case "string literal with escaped backslash" `Quick
            test_predicate_string_with_escaped_backslash;
          Alcotest.test_case "active = true" `Quick test_predicate_bool_true;
          Alcotest.test_case "active = false" `Quick test_predicate_bool_false;
          Alcotest.test_case "id <> 3 (inequality)" `Quick
            test_predicate_inequality;
          Alcotest.test_case "tolerates extra whitespace around tokens" `Quick
            test_predicate_tolerates_extra_whitespace;
          Alcotest.test_case "literal on the left and column on the right"
            `Quick test_predicate_literal_on_the_left;
          Alcotest.test_case "column = column" `Quick
            test_predicate_column_equals_column;
          Alcotest.test_case "column <> column" `Quick
            test_predicate_column_inequality_column;
          Alcotest.test_case
            "identifier with a bool-keyword prefix is a column reference" `Quick
            test_predicate_keyword_prefix_is_an_identifier;
          Alcotest.test_case "qualified column = literal" `Quick
            test_predicate_qualified_column_against_literal;
          Alcotest.test_case "qualified column = qualified column" `Quick
            test_predicate_qualified_column_against_qualified_column;
        ] );
      ( "predicate rejection",
        [
          Alcotest.test_case "rejects empty input" `Quick
            test_predicate_rejects_empty_input;
          Alcotest.test_case "rejects whitespace-only input" `Quick
            test_predicate_rejects_whitespace_only_input;
          Alcotest.test_case "rejects predicate missing an operator" `Quick
            test_predicate_rejects_missing_operator;
          Alcotest.test_case "rejects unterminated string literal" `Quick
            test_predicate_rejects_unterminated_string;
          Alcotest.test_case "rejects unrecognised escape sequence" `Quick
            test_predicate_rejects_unrecognised_escape;
          Alcotest.test_case "rejects trailing garbage" `Quick
            test_predicate_rejects_trailing_garbage;
          Alcotest.test_case
            "rejects qualified-reference dot with whitespace around it" `Quick
            test_predicate_rejects_dot_with_whitespace;
        ] );
      ( "pipeline syntax",
        [
          Alcotest.test_case "parses a single restrict step" `Quick
            test_pipeline_parses_single_restrict;
          Alcotest.test_case
            "two restrict steps nest left-associatively in the AST" `Quick
            test_pipeline_parses_two_restrict_steps_left_associative;
          Alcotest.test_case "tolerates extra whitespace around the pipe" `Quick
            test_pipeline_tolerates_extra_whitespace_around_pipe;
          Alcotest.test_case "rejects leading pipe" `Quick
            test_pipeline_rejects_leading_pipe;
          Alcotest.test_case "rejects trailing pipe" `Quick
            test_pipeline_rejects_trailing_pipe;
          Alcotest.test_case "rejects restrict without a predicate" `Quick
            test_pipeline_rejects_restrict_without_predicate;
          Alcotest.test_case "rejects restrict without an input" `Quick
            test_pipeline_rejects_restrict_without_input;
          Alcotest.test_case "rejects an unknown pipeline keyword" `Quick
            test_pipeline_rejects_unknown_keyword;
        ] );
      ( "project syntax",
        [
          Alcotest.test_case "parses a single-column project step" `Quick
            test_pipeline_parses_single_column_project;
          Alcotest.test_case "parses a multi-column project step" `Quick
            test_pipeline_parses_multi_column_project;
          Alcotest.test_case "parses project without spaces around the comma"
            `Quick test_pipeline_parses_project_without_spaces_around_comma;
          Alcotest.test_case "parses project with a space before the comma"
            `Quick test_pipeline_parses_project_with_space_before_comma;
          Alcotest.test_case "parses project that reorders columns" `Quick
            test_pipeline_parses_project_reordering_columns;
          Alcotest.test_case
            "parses two project steps nesting left-associatively" `Quick
            test_pipeline_parses_chained_project;
          Alcotest.test_case "parses restrict followed by project" `Quick
            test_pipeline_parses_restrict_then_project;
          Alcotest.test_case "parses project with qualified columns" `Quick
            test_pipeline_parses_project_with_qualified_columns;
          Alcotest.test_case "rejects project with no columns" `Quick
            test_pipeline_rejects_project_without_columns;
          Alcotest.test_case "rejects project with a leading comma" `Quick
            test_pipeline_rejects_project_with_leading_comma;
          Alcotest.test_case "rejects project with a trailing comma" `Quick
            test_pipeline_rejects_project_with_trailing_comma;
          Alcotest.test_case "rejects project columns separated by whitespace"
            `Quick test_pipeline_rejects_project_missing_comma;
        ] );
      ( "cross syntax",
        [
          Alcotest.test_case "parses a cross-product step" `Quick
            test_pipeline_parses_cross_product;
          Alcotest.test_case "parses cross product followed by restrict" `Quick
            test_pipeline_parses_cross_product_then_restrict;
          Alcotest.test_case "rejects cross without a right-hand relation"
            `Quick test_pipeline_rejects_cross_without_relation;
          Alcotest.test_case
            "identifier with a cross-keyword prefix is a relation name" `Quick
            test_pipeline_keyword_prefix_is_a_relation_name;
        ] );
      ( "pipeline integration",
        [
          Alcotest.test_case
            "parsed query, lowered/translated/evaluated, yields fixture rows"
            `Quick test_pipeline_yields_fixture_rows;
          Alcotest.test_case "parsed restrict pipeline yields filtered rows"
            `Quick test_pipeline_restrict_yields_filtered_rows;
          Alcotest.test_case "parsed project pipeline yields projected rows"
            `Quick test_pipeline_project_yields_projected_rows;
          Alcotest.test_case "parsed cross-product pipeline yields all pairs"
            `Quick test_pipeline_cross_yields_thirty_rows;
          Alcotest.test_case
            "parsed cross then restrict yields matched (user, order) pairs"
            `Quick test_pipeline_cross_then_restrict_yields_matched_pairs;
          Alcotest.test_case
            "parsed cross then unqualified restrict raises ambiguity" `Quick
            test_pipeline_cross_then_ambiguous_restrict_raises;
        ] );
    ]
