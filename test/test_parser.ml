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
    ]
