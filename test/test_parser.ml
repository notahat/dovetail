(** Tests for [Parser]. *)

open Dovetail
open Test_helpers

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

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

let id_equals_three =
  predicate_compare ~left:(predicate_column "id") ~op:Equal
    ~right:(predicate_literal (Value.Int64 3L))

let active_equals_true =
  predicate_compare
    ~left:(predicate_column "active")
    ~op:Equal
    ~right:(predicate_literal (Value.Bool true))

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
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "five rows from parsed query" expected_users_rows rows))

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
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Carol's row from parsed restrict"
            [ List.nth expected_users_rows 2 ]
            rows))

let users_relation = Ast.Relation_name "users"

let test_pipeline_parses_single_column_project () =
  parses "users | project name"
    (Ast.Project
       { input = users_relation; columns = [ column_reference "name" ] })

let test_pipeline_parses_multi_column_project () =
  parses "users | project name, email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ column_reference "name"; column_reference "email" ];
       })

let test_pipeline_parses_project_without_spaces_around_comma () =
  parses "users | project name,email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ column_reference "name"; column_reference "email" ];
       })

let test_pipeline_parses_project_with_space_before_comma () =
  parses "users | project name ,email"
    (Ast.Project
       {
         input = users_relation;
         columns = [ column_reference "name"; column_reference "email" ];
       })

let test_pipeline_parses_project_reordering_columns () =
  parses "users | project email, id"
    (Ast.Project
       {
         input = users_relation;
         columns = [ column_reference "email"; column_reference "id" ];
       })

let test_pipeline_parses_chained_project () =
  parses "users | project name | project email"
    (Ast.Project
       {
         input =
           Ast.Project
             { input = users_relation; columns = [ column_reference "name" ] };
         columns = [ column_reference "email" ];
       })

let test_pipeline_parses_restrict_then_project () =
  parses "users | restrict id = 3 | project name, email"
    (Ast.Project
       {
         input =
           Ast.Restrict { input = users_relation; predicate = id_equals_three };
         columns = [ column_reference "name"; column_reference "email" ];
       })

let test_pipeline_parses_project_with_qualified_columns () =
  parses "users | project users.name, users.email"
    (Ast.Project
       {
         input = users_relation;
         columns =
           [
             qualified_column_reference ~qualifier:"users" ~name:"name";
             qualified_column_reference ~qualifier:"users" ~name:"email";
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
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check int)
            "5 users x 6 orders = 30 rows from parsed cross" 30
            (List.length rows)))

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
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check int)
            "six matched (user, order) pairs from parsed pipeline" 6
            (List.length rows)))

let users_id_equals_orders_user_id =
  predicate_compare
    ~left:(predicate_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(predicate_qualified_column ~qualifier:"orders" ~name:"user_id")

let test_pipeline_parses_join_on_predicate () =
  parses "users | join orders on users.id = orders.user_id"
    (Ast.Join
       {
         left = users_relation;
         right = orders_relation;
         predicate = users_id_equals_orders_user_id;
       })

let test_pipeline_rejects_join_without_relation () = rejects "users | join"

let test_pipeline_rejects_join_without_on_keyword () =
  rejects "users | join orders"

let test_pipeline_rejects_join_without_predicate () =
  rejects "users | join orders on"

let test_pipeline_join_keyword_prefix_is_a_relation_name () =
  (* [joinery] starts with "join" but is a single identifier, so [users |
     joinery] should be rejected as an unknown pipeline keyword rather than
     parsed as a malformed join step. *)
  rejects "users | joinery orders on users.id = orders.user_id"

let test_pipeline_join_on_keyword_prefix_is_a_column_name () =
  (* [oncology] starts with "on" but is a single identifier, so it must not
     be mistaken for the [on] keyword inside the join step. With no real
     [on], the rest of the input is unparseable. *)
  rejects "users | join orders oncology users.id = orders.user_id"

let test_pipeline_join_yields_matched_pairs () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match
          Parser.parse "users | join orders on users.id = orders.user_id"
        with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check int)
            "six matched (user, order) pairs from parsed join" 6
            (List.length rows)))

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
           "Expression.resolve: ambiguous column reference \"id\": matches \
            \"users.id\" and \"orders.id\"") (fun () ->
          Eval.eval environment transaction physical (fun _relation -> ())))

let test_pipeline_restrict_bare_bool_column_yields_active_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict active" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check int)
            "three active rows from restrict active" 3 (List.length rows)))

let test_pipeline_restrict_constant_true_yields_all_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict 5 = 5" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "5 = 5 keeps every row" expected_users_rows rows))

let test_pipeline_restrict_with_int64_greater_than_yields_upper_rows () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id > 3" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Dave and Eve (ids > 3)"
            [ List.nth expected_users_rows 3; List.nth expected_users_rows 4 ]
            rows))

let test_pipeline_restrict_with_string_ge_yields_lex_subset () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict name >= \"C\"" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "names lexicographically >= \"C\": Carol, Dave, Eve"
            [
              List.nth expected_users_rows 2;
              List.nth expected_users_rows 3;
              List.nth expected_users_rows 4;
            ]
            rows))

let test_pipeline_restrict_and_intersects () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id > 1 and active" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Carol and Dave (id > 1 and active)"
            [ List.nth expected_users_rows 2; List.nth expected_users_rows 3 ]
            rows))

let test_pipeline_restrict_or_unions () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match
          Parser.parse "users | restrict name = \"Alice\" or name = \"Bob\""
        with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          Alcotest.(check tuple_list_testable)
            "Alice and Bob (union)"
            [ List.nth expected_users_rows 0; List.nth expected_users_rows 1 ]
            rows))

let test_pipeline_restrict_and_chain_is_left_associative () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id > 1 and id < 4 and active" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          (* id 1 < x < 4 = {2, 3}. Active among those: id 3 (Carol). *)
          Alcotest.(check tuple_list_testable)
            "Carol (id between 1 and 4, active)"
            [ List.nth expected_users_rows 2 ]
            rows))

let test_pipeline_restrict_mixed_and_or_follows_precedence () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id = 1 or id = 2 and active" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Eval.eval environment transaction physical (fun relation ->
          let rows = List.of_seq relation.tuples in
          (* Parses as [id = 1 or (id = 2 and active)]. Alice (id 1) always
             matches; Bob (id 2, inactive) doesn't. Result: Alice only. *)
          Alcotest.(check tuple_list_testable)
            "Alice only (precedence)"
            [ List.nth expected_users_rows 0 ]
            rows))

let test_pipeline_restrict_with_ordering_on_bool_raises () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict active > false" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Alcotest.check_raises "ordering operator on Bool operands"
        (Failure
           "Expression.resolve: ordering operator > is not defined for Bool")
        (fun () -> Eval.eval environment transaction physical (fun _ -> ())))

let test_pipeline_restrict_with_non_bool_expression_raises () =
  with_temp_dir @@ fun directory ->
  with_environment directory @@ fun environment ->
  Fixture.populate_if_empty environment;
  Storage.with_read_transaction environment (fun transaction ->
      let ast =
        match Parser.parse "users | restrict id" with
        | Ok ast -> ast
        | Error message -> Alcotest.failf "parse failed: %s" message
      in
      let logical = Lower.lower ast in
      let physical = Translate.translate logical in
      Alcotest.check_raises "non-Bool predicate from int64 column"
        (Failure
           "Expression.resolve: predicate position requires Bool, got Int64")
        (fun () -> Eval.eval environment transaction physical (fun _ -> ())))

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
      Eval.eval environment transaction physical (fun relation ->
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
            "five projected rows from parsed project" expected rows))

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
      ( "join syntax",
        [
          Alcotest.test_case "parses a join step with an on-predicate" `Quick
            test_pipeline_parses_join_on_predicate;
          Alcotest.test_case "rejects join without a right-hand relation" `Quick
            test_pipeline_rejects_join_without_relation;
          Alcotest.test_case "rejects join without the on keyword" `Quick
            test_pipeline_rejects_join_without_on_keyword;
          Alcotest.test_case "rejects join without a predicate after on" `Quick
            test_pipeline_rejects_join_without_predicate;
          Alcotest.test_case
            "identifier with a join-keyword prefix is not the join step" `Quick
            test_pipeline_join_keyword_prefix_is_a_relation_name;
          Alcotest.test_case
            "identifier with an on-keyword prefix is not the on keyword" `Quick
            test_pipeline_join_on_keyword_prefix_is_a_column_name;
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
          Alcotest.test_case "parsed join yields matched (user, order) pairs"
            `Quick test_pipeline_join_yields_matched_pairs;
          Alcotest.test_case
            "parsed cross then unqualified restrict raises ambiguity" `Quick
            test_pipeline_cross_then_ambiguous_restrict_raises;
          Alcotest.test_case
            "parsed restrict with a bare bool column yields active rows" `Quick
            test_pipeline_restrict_bare_bool_column_yields_active_rows;
          Alcotest.test_case
            "parsed restrict with a constant-true comparison keeps every row"
            `Quick test_pipeline_restrict_constant_true_yields_all_rows;
          Alcotest.test_case
            "parsed restrict with a non-Bool expression raises at resolve time"
            `Quick test_pipeline_restrict_with_non_bool_expression_raises;
          Alcotest.test_case
            "parsed restrict id > 3 yields the rows above the bound" `Quick
            test_pipeline_restrict_with_int64_greater_than_yields_upper_rows;
          Alcotest.test_case
            "parsed restrict name >= \"C\" yields the lex-ordered upper subset"
            `Quick test_pipeline_restrict_with_string_ge_yields_lex_subset;
          Alcotest.test_case "parsed restrict active > false raises naming Bool"
            `Quick test_pipeline_restrict_with_ordering_on_bool_raises;
          Alcotest.test_case
            "parsed restrict id > 1 and active intersects the two conditions"
            `Quick test_pipeline_restrict_and_intersects;
          Alcotest.test_case
            "parsed restrict name = ... or name = ... unions the rows" `Quick
            test_pipeline_restrict_or_unions;
          Alcotest.test_case "parsed restrict with a left-associative and-chain"
            `Quick test_pipeline_restrict_and_chain_is_left_associative;
          Alcotest.test_case
            "parsed restrict mixing and/or follows declared precedence" `Quick
            test_pipeline_restrict_mixed_and_or_follows_precedence;
        ] );
    ]
