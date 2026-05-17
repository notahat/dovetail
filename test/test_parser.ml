(** Tests for [Parser]. *)

open Dovetail
open Test_helpers

let ast_program_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast-program>")) ( = )

(* Wraps the expected [Ast.t] in [Ast.Pipeline (Ast.Query ...)] before
   comparing against the parser's [Ast.program] output. Most surface forms
   parse as pipeline queries; the sink-production tests below use
   [parses_plan] to assert against a [Mutation], and the DDL tests use
   [parses_program] to assert against an [Ast.Ddl] directly. *)
let parses input expected_inner_ast =
  match Parser.parse input with
  | Ok actual_program ->
      Alcotest.(check ast_program_testable)
        (Printf.sprintf "%S parses" input)
        (Ast.Pipeline (Ast.Query expected_inner_ast)) actual_program
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

(* Stricter form of [rejects]: assert the parser fails AND that the error
   message contains every fragment in [mentions]. Used by the slice-11
   validation-polish tests, where the wording is part of the contract --
   "names the offending column" is a guarantee tests should observe. *)
let rejects_with_message input ~mentions =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error message ->
      List.iter
        (fun fragment ->
          if not (contains_substring message fragment) then
            Alcotest.failf "expected %S's parse error to mention %S, got: %s"
              input fragment message)
        mentions

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
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Value.Int64 3L))

let active_equals_true =
  expression_compare
    ~left:(expression_column "active")
    ~op:Equal
    ~right:(expression_literal (Value.Bool true))

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
  expression_compare
    ~left:(expression_qualified_column ~qualifier:"users" ~name:"id")
    ~op:Equal
    ~right:(expression_qualified_column ~qualifier:"orders" ~name:"user_id")

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

let test_relation_literal_parses_single_pair () =
  parses "{id: 7}"
    (Ast.RelationLiteral { columns = [ "id" ]; rows = [ [ Value.Int64 7L ] ] })

let test_relation_literal_parses_multiple_pairs () =
  parses "{id: 7, name: \"Pretzel\", active: true}"
    (Ast.RelationLiteral
       {
         columns = [ "id"; "name"; "active" ];
         rows = [ [ Value.Int64 7L; Value.String "Pretzel"; Value.Bool true ] ];
       })

let test_relation_literal_tolerates_trailing_comma () =
  parses "{id: 7, name: \"Pretzel\",}"
    (Ast.RelationLiteral
       {
         columns = [ "id"; "name" ];
         rows = [ [ Value.Int64 7L; Value.String "Pretzel" ] ];
       })

let test_relation_literal_tolerates_extra_whitespace () =
  parses "{  id  :  7  ,  name  :  \"Pretzel\"  }"
    (Ast.RelationLiteral
       {
         columns = [ "id"; "name" ];
         rows = [ [ Value.Int64 7L; Value.String "Pretzel" ] ];
       })

let test_relation_literal_accepts_negative_int () =
  parses "{amount: -5}"
    (Ast.RelationLiteral
       { columns = [ "amount" ]; rows = [ [ Value.Int64 (-5L) ] ] })

let test_relation_literal_alone_is_a_valid_pipeline_head () =
  parses "{id: 7} | restrict id = 7"
    (Ast.Restrict
       {
         input =
           Ast.RelationLiteral
             { columns = [ "id" ]; rows = [ [ Value.Int64 7L ] ] };
         predicate =
           expression_compare ~left:(expression_column "id") ~op:Equal
             ~right:(expression_literal (Value.Int64 7L));
       })

let test_relation_literal_rejects_empty () = rejects "{}"
let test_relation_literal_rejects_leading_comma () = rejects "{, id: 7}"

(* The error must name the duplicate so the user can find it; ["id"] in the
   "mentions" list is the column name and "duplicate column" is the kind of
   problem. *)
let test_relation_literal_rejects_duplicate_column () =
  rejects_with_message "{id: 1, id: 2}"
    ~mentions:[ "duplicate column"; "\"id\"" ]

(* The error must name the full qualified key ["users.id"] -- not just
   "users" -- so the user sees exactly what they typed. The wording
   "qualified column key" labels the kind of problem. *)
let test_relation_literal_rejects_qualified_key () =
  rejects_with_message "{users.id: 7}"
    ~mentions:[ "qualified column key"; "\"users.id\"" ]

(* The same check has to fire mid-literal, not just on the first pair --
   the qualified-key detection sits inside [relation_literal_pair], which
   runs once per pair, but the angstrom [many] wrapping is easy to get
   wrong so we lock in the second-position case with a dedicated test. *)
let test_relation_literal_rejects_qualified_key_in_second_position () =
  rejects_with_message "{x: 1, orders.amount: 2}"
    ~mentions:[ "qualified column key"; "\"orders.amount\"" ]

let test_relation_literal_rejects_missing_colon () = rejects "{id 7}"
let test_relation_literal_rejects_missing_value () = rejects "{id:}"

let test_relation_literal_rejects_column_reference_in_value_position () =
  rejects "{id: x}"

(* Slice 11 step 4: the sink production. A pipeline that ends in [| insert
   into <table>] parses as an [Ast.Mutation], with everything before the
   sink as the upstream relation. Pipelines without a sink parse as
   [Ast.Query]. The wrapper is the parser's only structural change at this
   step. *)

let parses_plan input expected_plan =
  match Parser.parse input with
  | Ok actual_program ->
      Alcotest.(check ast_program_testable)
        (Printf.sprintf "%S parses to plan" input)
        (Ast.Pipeline expected_plan) actual_program
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

(* Bare program assertion: compare against an arbitrary [Ast.program]
   without the [Pipeline] wrapping that {!parses} and {!parses_plan}
   provide. The DDL tests below use this to assert against [Ast.Ddl]
   constructors directly. *)
let parses_program input expected_program =
  match Parser.parse input with
  | Ok actual_program ->
      Alcotest.(check ast_program_testable)
        (Printf.sprintf "%S parses to program" input)
        expected_program actual_program
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let test_pipeline_ending_in_sink_parses_as_mutation () =
  parses_plan
    "{id: 9, user_id: 1, description: \"Pretzel\", amount: 9} | insert into \
     orders"
    (Ast.Mutation
       (Insert
          {
            source =
              Ast.RelationLiteral
                {
                  columns = [ "id"; "user_id"; "description"; "amount" ];
                  rows =
                    [
                      [
                        Value.Int64 9L;
                        Value.Int64 1L;
                        Value.String "Pretzel";
                        Value.Int64 9L;
                      ];
                    ];
                };
            table = "orders";
          }))

let test_pipeline_without_sink_parses_as_query () =
  parses_plan "users" (Ast.Query (Ast.Relation_name "users"))

let test_pipeline_with_upstream_pipeline_then_sink_parses_as_mutation () =
  parses_plan "users | insert into orders"
    (Ast.Mutation
       (Insert { source = Ast.Relation_name "users"; table = "orders" }))

let test_pipeline_rejects_query_op_after_sink () =
  (* The grammar admits at most one sink, in terminal position. A
     [restrict] (or any other [query_op]) after [| insert into ...] is a
     parse error. *)
  rejects "users | insert into orders | restrict id = 1"

let test_pipeline_rejects_sink_with_nothing_before_it () =
  rejects "| insert into orders"

let test_pipeline_rejects_sink_without_target_table () =
  rejects "users | insert into"

let test_pipeline_rejects_sink_without_into_keyword () =
  rejects "users | insert orders"

let test_pipeline_rejects_two_sinks () =
  rejects "users | insert into orders | insert into orders"

(* Slice 12 step 3: the DDL sigil. A leading [:] (after any optional
   whitespace) marks a DDL statement; slice 12 admits [:list tables] only
   at this step, with [:drop table <name>] arriving in step 5b. The sigil
   is recognised only at the top of input -- a [:] inside a pipeline is a
   parse error rather than an embedded DDL statement. *)

let test_ddl_list_tables_parses () =
  parses_program ":list tables" (Ast.Ddl Ddl.List_tables)

let test_ddl_list_tables_tolerates_leading_whitespace () =
  parses_program "   :list tables" (Ast.Ddl Ddl.List_tables)

let test_ddl_list_tables_tolerates_whitespace_after_sigil () =
  parses_program ":   list tables" (Ast.Ddl Ddl.List_tables)

let test_ddl_list_tables_tolerates_extra_whitespace_between_keywords () =
  parses_program ":list    tables" (Ast.Ddl Ddl.List_tables)

let test_ddl_list_tables_tolerates_trailing_whitespace () =
  parses_program ":list tables    " (Ast.Ddl Ddl.List_tables)

let test_ddl_rejects_bare_sigil () = rejects ":"
let test_ddl_rejects_unknown_body () = rejects ":list"
let test_ddl_rejects_unknown_keyword () = rejects ":wibble"
let test_ddl_rejects_trailing_garbage () = rejects ":list tables xyz"

let test_ddl_sigil_mid_pipeline_is_parse_error () =
  rejects "users | :drop table x"

(* The DDL keywords are not globally reserved -- [list] and [tables] are
   valid identifiers inside a pipeline. This locks in that the sigil is
   what reserves them, and the reservation is bounded to the DDL body. *)
let test_pipeline_keyword_list_is_a_relation_name () =
  parses "list" (Ast.Relation_name "list")

let test_pipeline_keyword_tables_is_a_relation_name () =
  parses "tables" (Ast.Relation_name "tables")

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
      ( "relation literal syntax",
        [
          Alcotest.test_case "parses a single-pair literal" `Quick
            test_relation_literal_parses_single_pair;
          Alcotest.test_case "parses a multi-pair literal" `Quick
            test_relation_literal_parses_multiple_pairs;
          Alcotest.test_case "tolerates a trailing comma" `Quick
            test_relation_literal_tolerates_trailing_comma;
          Alcotest.test_case "tolerates extra whitespace inside the literal"
            `Quick test_relation_literal_tolerates_extra_whitespace;
          Alcotest.test_case "accepts a negative int64 value" `Quick
            test_relation_literal_accepts_negative_int;
          Alcotest.test_case "a literal alone is a valid pipeline head" `Quick
            test_relation_literal_alone_is_a_valid_pipeline_head;
          Alcotest.test_case "rejects the empty literal" `Quick
            test_relation_literal_rejects_empty;
          Alcotest.test_case "rejects a literal with a leading comma" `Quick
            test_relation_literal_rejects_leading_comma;
          Alcotest.test_case "rejects a literal with a duplicate column" `Quick
            test_relation_literal_rejects_duplicate_column;
          Alcotest.test_case "rejects a literal with a qualified key" `Quick
            test_relation_literal_rejects_qualified_key;
          Alcotest.test_case
            "rejects a literal with a qualified key in second position" `Quick
            test_relation_literal_rejects_qualified_key_in_second_position;
          Alcotest.test_case "rejects a literal missing the colon" `Quick
            test_relation_literal_rejects_missing_colon;
          Alcotest.test_case "rejects a literal with a missing value" `Quick
            test_relation_literal_rejects_missing_value;
          Alcotest.test_case "rejects a column reference in the value position"
            `Quick
            test_relation_literal_rejects_column_reference_in_value_position;
        ] );
      ( "insert sink syntax",
        [
          Alcotest.test_case "pipeline ending in a sink parses as Mutation"
            `Quick test_pipeline_ending_in_sink_parses_as_mutation;
          Alcotest.test_case "pipeline without a sink parses as Query" `Quick
            test_pipeline_without_sink_parses_as_query;
          Alcotest.test_case
            "upstream pipeline followed by a sink parses as Mutation" `Quick
            test_pipeline_with_upstream_pipeline_then_sink_parses_as_mutation;
          Alcotest.test_case "rejects a query operator after the sink" `Quick
            test_pipeline_rejects_query_op_after_sink;
          Alcotest.test_case "rejects a sink with nothing before it" `Quick
            test_pipeline_rejects_sink_with_nothing_before_it;
          Alcotest.test_case "rejects a sink without a target table" `Quick
            test_pipeline_rejects_sink_without_target_table;
          Alcotest.test_case "rejects a sink without the into keyword" `Quick
            test_pipeline_rejects_sink_without_into_keyword;
          Alcotest.test_case "rejects two sinks in the same pipeline" `Quick
            test_pipeline_rejects_two_sinks;
        ] );
      ( "ddl syntax",
        [
          Alcotest.test_case ":list tables parses to Ddl List_tables" `Quick
            test_ddl_list_tables_parses;
          Alcotest.test_case "tolerates whitespace before the sigil" `Quick
            test_ddl_list_tables_tolerates_leading_whitespace;
          Alcotest.test_case "tolerates whitespace after the sigil" `Quick
            test_ddl_list_tables_tolerates_whitespace_after_sigil;
          Alcotest.test_case "tolerates extra whitespace between keywords"
            `Quick
            test_ddl_list_tables_tolerates_extra_whitespace_between_keywords;
          Alcotest.test_case "tolerates trailing whitespace" `Quick
            test_ddl_list_tables_tolerates_trailing_whitespace;
          Alcotest.test_case "rejects a bare sigil" `Quick
            test_ddl_rejects_bare_sigil;
          Alcotest.test_case "rejects an unknown body" `Quick
            test_ddl_rejects_unknown_body;
          Alcotest.test_case "rejects an unknown DDL keyword" `Quick
            test_ddl_rejects_unknown_keyword;
          Alcotest.test_case "rejects trailing garbage after the body" `Quick
            test_ddl_rejects_trailing_garbage;
          Alcotest.test_case "rejects a sigil mid-pipeline" `Quick
            test_ddl_sigil_mid_pipeline_is_parse_error;
          Alcotest.test_case "[list] is a relation name in a pipeline" `Quick
            test_pipeline_keyword_list_is_a_relation_name;
          Alcotest.test_case "[tables] is a relation name in a pipeline" `Quick
            test_pipeline_keyword_tables_is_a_relation_name;
        ] );
    ]
