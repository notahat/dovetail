(** Tests for [Parser]. *)

open Dovetail_surface_ra
open Test_helpers
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

let ast_testable = Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast>")) ( = )

(* Compare the parser's output against an expected [Ast.t]. The
   sink-production tests below build an [Ast.Insert] using {!parses_plan}. *)
let parses input expected_ast =
  match Parser.parse input with
  | Ok actual_ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses" input)
        expected_ast actual_ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let rejects input =
  match Parser.parse input with
  | Ok _ -> Alcotest.failf "expected %S to be rejected, but it parsed" input
  | Error _ -> ()

(* Stricter form of [rejects]: assert the parser fails AND that the error
   message contains every fragment in [mentions]. Used by the
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
  (* Multiple tokens are out of scope for the grammar; the parser must
     refuse them so we don't accidentally start accepting them later. *)
  rejects "users orders"

let id_equals_three =
  expression_compare ~left:(expression_column "id") ~op:Equal
    ~right:(expression_literal (Scalar.Int64 3L))

let active_equals_true =
  expression_compare
    ~left:(expression_column "active")
    ~op:Equal
    ~right:(expression_literal (Scalar.Bool true))

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

(* The sink production. A pipeline that ends in [| insert into <table>]
   parses as an [Ast.Insert] with everything before the sink as the
   upstream relation. Pipelines without a sink parse as the relation
   expression itself. *)

let parses_plan input expected_plan =
  match Parser.parse input with
  | Ok actual_ast ->
      Alcotest.(check ast_testable)
        (Printf.sprintf "%S parses to plan" input)
        expected_plan actual_ast
  | Error message ->
      Alcotest.failf "expected %S to parse but got error: %s" input message

let test_pipeline_ending_in_sink_parses_as_insert () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "user_id"; kind = Int64; qualifier = None };
          { name = "description"; kind = String; qualifier = None };
          { name = "amount"; kind = Int64; qualifier = None };
        ];
      refinements = [];
    }
  in
  parses_plan
    "relation (id: int64, user_id: int64, description: string, amount: int64) \
     { (id = 9, user_id = 1, description = \"Pretzel\", amount = 9) } | insert \
     into orders"
    (Ast.Insert
       {
         source =
           Ast.Relation_literal
             {
               kind;
               rows =
                 [
                   [
                     (column_reference "id", Scalar.Int64 9L);
                     (column_reference "user_id", Scalar.Int64 1L);
                     (column_reference "description", Scalar.String "Pretzel");
                     (column_reference "amount", Scalar.Int64 9L);
                   ];
                 ];
             };
         table = "orders";
       })

let test_pipeline_without_sink_parses_as_relation () =
  parses_plan "users" (Ast.Relation_name "users")

let test_pipeline_with_upstream_pipeline_then_sink_parses_as_insert () =
  parses_plan "users | insert into orders"
    (Ast.Insert { source = Ast.Relation_name "users"; table = "orders" })

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

(* The [create table] sink in its seeded form. A value-yielding upstream
   pipeline followed by [| create table <name>] parses as
   [Ast.Create_table_seeded]. The empty form (a type expression on the
   left) is handled by a separate dispatcher introduced later; for now,
   only the value-pipeline source is admitted by the sink itself. *)

let test_pipeline_create_table_seeded_with_relation_literal_source_parses () =
  let kind : Relation.kind =
    {
      row_kind =
        [
          { name = "id"; kind = Int64; qualifier = None };
          { name = "name"; kind = String; qualifier = None };
        ];
      refinements = [];
    }
  in
  parses_plan
    "relation (id: int64, name: string) { (id = 1, name = \"alice\") } | \
     create table users"
    (Ast.Create_table_seeded
       {
         table_name = "users";
         source =
           Ast.Relation_literal
             {
               kind;
               rows =
                 [
                   [
                     (column_reference "id", Scalar.Int64 1L);
                     (column_reference "name", Scalar.String "alice");
                   ];
                 ];
             };
       })

let test_pipeline_create_table_seeded_with_relation_name_source_parses () =
  parses_plan "users | create table users_copy"
    (Ast.Create_table_seeded
       { table_name = "users_copy"; source = Ast.Relation_name "users" })

let test_pipeline_create_table_seeded_with_upstream_steps_parses () =
  parses_plan "users | project id | create table user_ids"
    (Ast.Create_table_seeded
       {
         table_name = "user_ids";
         source =
           Ast.Project
             {
               input = Ast.Relation_name "users";
               columns = [ column_reference "id" ];
             };
       })

let test_pipeline_create_table_sink_rejects_query_op_after_it () =
  rejects "users | create table users_copy | restrict id = 1"

let test_pipeline_create_table_sink_rejects_with_nothing_before_it () =
  rejects "| create table users"

let test_pipeline_create_table_sink_rejects_without_target_table () =
  rejects "users | create table"

let test_pipeline_create_table_sink_rejects_without_table_keyword () =
  rejects "users | create users_copy"

let test_pipeline_create_table_sink_rejects_two_sinks () =
  rejects "users | create table aaa | create table bbb"

let test_pipeline_create_table_then_insert_into_is_rejected () =
  rejects "users | create table a | insert into b"

let test_pipeline_insert_into_then_create_table_is_rejected () =
  rejects "users | insert into a | create table b"

(* The [create table] sink in its empty form. A type expression on the
   left of the sink builds an [Ast.Create_table_empty] node carrying
   the parsed [type_expression] verbatim. The dispatcher at the top of
   the pipeline grammar uses bounded lookahead to tell a type expression
   ([(name: kind, ...)]) from a value-literal ([(name = value, ...)])
   or the empty form [()]; the type-expression path commits only to the
   [create table] sink, so a type expression piped into anything else
   is a parse error. *)

let test_pipeline_create_table_empty_with_simple_type_expression_parses () =
  parses_plan "(id: int64, name: string) | create table users"
    (Ast.Create_table_empty
       {
         table_name = "users";
         type_expression =
           {
             fields =
               [
                 { qualifier = None; name = "id"; kind = Int64 };
                 { qualifier = None; name = "name"; kind = String };
               ];
             refinements = [];
           };
       })

let test_pipeline_create_table_empty_with_primary_key_parses () =
  parses_plan "(id: int64, name: string, primary key (id)) | create table users"
    (Ast.Create_table_empty
       {
         table_name = "users";
         type_expression =
           {
             fields =
               [
                 { qualifier = None; name = "id"; kind = Int64 };
                 { qualifier = None; name = "name"; kind = String };
               ];
             refinements = [ Relation.Primary_key [ "id" ] ];
           };
       })

let test_pipeline_create_table_empty_tolerates_extra_whitespace () =
  parses_plan "  (id:  int64)\n  |  create   table   users  "
    (Ast.Create_table_empty
       {
         table_name = "users";
         type_expression =
           {
             fields = [ { qualifier = None; name = "id"; kind = Int64 } ];
             refinements = [];
           };
       })

let test_pipeline_empty_parens_dispatches_to_value_literal_branch () =
  (* Empty parens [()] are ambiguous between an empty type expression
     and an empty row literal. The dispatcher resolves them as the
     value-literal form to preserve the existing behaviour of [()] as a
     row literal; the downstream [create table] sink therefore builds a
     [Create_table_seeded] over a [Row_literal []]. The structural
     "column list is empty" check fires later, at evaluation time. *)
  parses_plan "() | create table foo"
    (Ast.Create_table_seeded { table_name = "foo"; source = Ast.Row_literal [] })

let test_pipeline_type_expression_piped_into_restrict_is_rejected () =
  rejects "(id: int64) | restrict id = 5"

let test_pipeline_type_expression_piped_into_insert_into_is_rejected () =
  rejects "(id: int64) | insert into users"

let test_pipeline_bare_type_expression_without_sink_is_rejected () =
  (* A type expression on its own is not a value-yielding pipeline; the
     dispatcher's type-expression branch commits only to the [create
     table] sink, so a bare type expression with no sink is a parse
     error. *)
  rejects "(id: int64)"

let test_pipeline_parens_with_colon_and_equals_mixed_is_rejected () =
  (* [(name = "x", id: int64)] is neither a valid row literal (the [:]
     is not a row-literal token) nor a valid type expression (the [=]
     is not a type-expression token), so both dispatcher branches fail
     and the parse is rejected. *)
  rejects "(name = \"x\", id: int64) | create table users"

(* The retired DDL sigil. A leading [:] used to introduce a
   data-definition statement; every form has since been retired in
   favour of pipe-form operators. The sigil is no longer recognised
   anywhere -- a leading [:list tables] is now a parse error just like
   any other unknown input. *)

let test_ddl_list_tables_is_no_longer_recognised () = rejects ":list tables"

(* The [:drop table] DDL form has been retired in favour of the
   [drop table <name>] pipe-source leaf. The sigil form is now
   rejected outright. *)
let test_ddl_drop_table_is_no_longer_recognised () = rejects ":drop table users"

(* A bare [drop] at pipeline-source position commits to the [drop table
   <name>] leaf grammar; if [table] doesn't follow, the parse fails
   rather than silently treating [drop] as a relation name. Mirrors the
   [relation] case. The keyword [table] is still a relation name -- only
   [drop] is reserved at source position. *)
let test_pipeline_keyword_drop_alone_is_rejected () = rejects "drop"

let test_pipeline_drop_table_parses_as_drop_table_leaf () =
  parses "drop table users" (Ast.Drop_table { table_name = "users" })

let test_pipeline_drop_table_tolerates_extra_whitespace () =
  parses "drop   table\n  users" (Ast.Drop_table { table_name = "users" })

let test_pipeline_drop_table_allows_downstream_pipeline_step () =
  (* Drop_table is a leaf source: its result is a relation, so a
     downstream pipeline step is grammatically legal even though the
     query is pointless. *)
  parses "drop table users | project dropped"
    (Ast.Project
       {
         input = Ast.Drop_table { table_name = "users" };
         columns = [ column_reference "dropped" ];
       })

let test_pipeline_drop_followed_by_non_table_keyword_is_rejected () =
  rejects "drop notatable users"

let test_pipeline_keyword_table_is_a_relation_name () =
  parses "table" (Ast.Relation_name "table")

let test_ddl_rejects_bare_sigil () = rejects ":"
let test_ddl_rejects_unknown_body () = rejects ":list"
let test_ddl_rejects_unknown_keyword () = rejects ":wibble"
let test_ddl_rejects_trailing_garbage () = rejects ":list tables xyz"

let test_ddl_sigil_mid_pipeline_is_parse_error () =
  rejects "users | :drop table x"

let test_ddl_describe_is_no_longer_recognised () =
  (* [:describe] used to be a DDL statement; the [type] pipe operator
     replaces it. The parser should now reject the sigil form. *)
  rejects ":describe users"

(* The [:create table] DDL form has been retired in favour of the
   pipe-form sink ([<type-expr> | create table <name>]). The sigil
   form should now be rejected outright. *)
let test_ddl_create_table_is_no_longer_recognised () =
  rejects ":create table widgets (id: Int64) primary key (id)"

(* The DDL keyword [create] is not globally reserved -- matches the
   [list] / [tables] / [drop] / [table] cases above. *)
let test_pipeline_keyword_create_is_a_relation_name () =
  parses "create" (Ast.Relation_name "create")

(* The bare [catalog] keyword at pipeline-source position is reserved: it
   yields the database's catalog rather than naming a relation called
   [catalog]. *)
let test_pipeline_bare_catalog_parses_as_catalog_source () =
  parses "catalog" Ast.Catalog_source

let test_pipeline_catalog_tolerates_surrounding_whitespace () =
  parses "  catalog\n" Ast.Catalog_source

let test_pipeline_catalog_allows_downstream_pipeline_step () =
  (* Catalog_source is a leaf; downstream steps compose over it just like
     any other leaf source. The [type] step is the simplest grammatical
     witness; semantic checks land in later steps. *)
  parses "catalog | type" (Ast.Type { input = Ast.Catalog_source })

let test_pipeline_tables_step_wraps_upstream () =
  parses "catalog | tables" (Ast.Tables { input = Ast.Catalog_source })

let test_pipeline_tables_then_type_composes () =
  parses "catalog | tables | type"
    (Ast.Type { input = Ast.Tables { input = Ast.Catalog_source } })

let test_pipeline_parses_type_step () =
  parses "users | type" (Ast.Type { input = Ast.Relation_name "users" })

let test_pipeline_parses_nested_type_step () =
  (* The grammar doesn't restrict where [type] appears; [Lower.lower] is
     the layer that rejects a type applied to a type. *)
  parses "users | type | type"
    (Ast.Type { input = Ast.Type { input = Ast.Relation_name "users" } })

let test_pipeline_parses_unqualify_step () =
  parses "users | unqualify"
    (Ast.Unqualify { input = Ast.Relation_name "users" })

let test_pipeline_parses_unqualify_after_join () =
  parses "users | join orders on users.id = orders.user_id | unqualify"
    (Ast.Unqualify
       {
         input =
           Ast.Join
             {
               left = Ast.Relation_name "users";
               right = Ast.Relation_name "orders";
               predicate =
                 Expression.Compare
                   {
                     left =
                       Expression.Column
                         { qualifier = Some "users"; name = "id" };
                     op = Expression.Equal;
                     right =
                       Expression.Column
                         { qualifier = Some "orders"; name = "user_id" };
                   };
             };
       })

let test_pipeline_keyword_type_is_a_relation_name () =
  (* [type] is reserved only in pipe-step position; as a pipeline head it's
     a bare identifier, same as the DDL keywords. *)
  parses "type" (Ast.Relation_name "type")

(* Bare scalar literals at pipeline-source position. *)

let test_scalar_literal_int64_parses_as_pipeline_source () =
  parses "42" (Ast.Scalar_literal (Scalar.Int64 42L))

let test_scalar_literal_negative_int64_parses () =
  parses "-7" (Ast.Scalar_literal (Scalar.Int64 (-7L)))

let test_scalar_literal_string_parses () =
  parses "\"hello\"" (Ast.Scalar_literal (Scalar.String "hello"))

let test_scalar_literal_true_parses_as_bool () =
  parses "true" (Ast.Scalar_literal (Scalar.Bool true))

let test_scalar_literal_false_parses_as_bool () =
  parses "false" (Ast.Scalar_literal (Scalar.Bool false))

let test_scalar_literal_tolerates_surrounding_whitespace () =
  parses "   42\n" (Ast.Scalar_literal (Scalar.Int64 42L))

let test_scalar_literal_followed_by_type_step () =
  parses "42 | type"
    (Ast.Type { input = Ast.Scalar_literal (Scalar.Int64 42L) })

(* Bare row literals at pipeline-source position. *)

let test_row_literal_empty_parses () = parses "()" (Ast.Row_literal [])

let test_row_literal_single_field_parses () =
  parses "(id = 1)"
    (Ast.Row_literal [ (column_reference "id", Scalar.Int64 1L) ])

let test_row_literal_multiple_fields_parses () =
  parses "(id = 1, name = \"alice\", active = true)"
    (Ast.Row_literal
       [
         (column_reference "id", Scalar.Int64 1L);
         (column_reference "name", Scalar.String "alice");
         (column_reference "active", Scalar.Bool true);
       ])

let test_row_literal_tolerates_trailing_comma () =
  parses "(id = 1, name = \"alice\",)"
    (Ast.Row_literal
       [
         (column_reference "id", Scalar.Int64 1L);
         (column_reference "name", Scalar.String "alice");
       ])

let test_row_literal_tolerates_extra_whitespace () =
  parses "(  id  =  1  ,  name  =  \"alice\"  )"
    (Ast.Row_literal
       [
         (column_reference "id", Scalar.Int64 1L);
         (column_reference "name", Scalar.String "alice");
       ])

let test_row_literal_rejects_duplicate_field () =
  rejects_with_message "(id = 1, id = 2)"
    ~mentions:[ "duplicate field"; "\"id\"" ]

let test_row_literal_rejects_missing_equals () = rejects "(id 1)"
let test_row_literal_rejects_missing_value () = rejects "(id =)"
let test_row_literal_rejects_leading_comma () = rejects "(, id = 1)"

let test_row_literal_followed_by_type_step () =
  parses "(id = 1, name = \"alice\") | type"
    (Ast.Type
       {
         input =
           Ast.Row_literal
             [
               (column_reference "id", Scalar.Int64 1L);
               (column_reference "name", Scalar.String "alice");
             ];
       })

(* Qualified row-literal fields. The dotted [qualifier.name] form parses
   straight through into the field list; the qualifier survives onto the
   column reference. *)

let test_row_literal_parses_qualified_field () =
  parses "(users.id = 1)"
    (Ast.Row_literal
       [
         ( qualified_column_reference ~qualifier:"users" ~name:"id",
           Scalar.Int64 1L );
       ])

let test_row_literal_parses_mixed_qualified_and_unqualified () =
  parses "(users.id = 1, name = \"alice\")"
    (Ast.Row_literal
       [
         ( qualified_column_reference ~qualifier:"users" ~name:"id",
           Scalar.Int64 1L );
         (column_reference "name", Scalar.String "alice");
       ])

let test_row_literal_allows_same_bare_name_under_different_qualifiers () =
  (* The qualified names differ, so the dedup check accepts them. *)
  parses "(users.id = 1, orders.id = 2)"
    (Ast.Row_literal
       [
         ( qualified_column_reference ~qualifier:"users" ~name:"id",
           Scalar.Int64 1L );
         ( qualified_column_reference ~qualifier:"orders" ~name:"id",
           Scalar.Int64 2L );
       ])

let test_row_literal_rejects_duplicate_qualified_field () =
  (* The dotted name is fully qualified, so [users.id] repeated is a
     duplicate. The error names the offending qualified spelling. *)
  rejects_with_message "(users.id = 1, users.id = 2)"
    ~mentions:[ "duplicate field"; "users.id" ]

(* Typed relation literals: [relation (T) { rows }]. *)

let id_int64_name_string_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = None };
        { name = "name"; kind = String; qualifier = None };
      ];
    refinements = [];
  }

let test_relation_literal_empty_parses () =
  parses "relation (id: int64, name: string) {}"
    (Ast.Relation_literal { kind = id_int64_name_string_kind; rows = [] })

let alice_row =
  [
    (column_reference "id", Scalar.Int64 1L);
    (column_reference "name", Scalar.String "alice");
  ]

let bob_row =
  [
    (column_reference "id", Scalar.Int64 2L);
    (column_reference "name", Scalar.String "bob");
  ]

let test_relation_literal_single_row_parses () =
  parses "relation (id: int64, name: string) { (id = 1, name = \"alice\") }"
    (Ast.Relation_literal
       { kind = id_int64_name_string_kind; rows = [ alice_row ] })

let test_relation_literal_multiple_rows_parses () =
  parses
    "relation (id: int64, name: string) { (id = 1, name = \"alice\"), (id = 2, \
     name = \"bob\") }"
    (Ast.Relation_literal
       { kind = id_int64_name_string_kind; rows = [ alice_row; bob_row ] })

let test_relation_literal_tolerates_trailing_comma () =
  parses
    "relation (id: int64, name: string) { (id = 1, name = \"alice\"), (id = 2, \
     name = \"bob\"), }"
    (Ast.Relation_literal
       { kind = id_int64_name_string_kind; rows = [ alice_row; bob_row ] })

let test_relation_literal_with_primary_key_refinement_parses () =
  parses "relation (id: int64, name: string, primary key (id)) {}"
    (Ast.Relation_literal
       {
         kind =
           {
             row_kind =
               [
                 { name = "id"; kind = Int64; qualifier = None };
                 { name = "name"; kind = String; qualifier = None };
               ];
             refinements = [ Primary_key [ "id" ] ];
           };
         rows = [];
       })

let test_relation_literal_tolerates_extra_whitespace () =
  parses "  relation  (  id : int64  )  {  ( id = 1 )  ,  ( id = 2 )  }  "
    (Ast.Relation_literal
       {
         kind =
           {
             row_kind = [ { name = "id"; kind = Int64; qualifier = None } ];
             refinements = [];
           };
         rows =
           [
             [ (column_reference "id", Scalar.Int64 1L) ];
             [ (column_reference "id", Scalar.Int64 2L) ];
           ];
       })

let test_relation_literal_rejects_duplicate_field_in_row () =
  rejects_with_message "relation (id: int64) { (id = 1, id = 2) }"
    ~mentions:[ "duplicate field"; "\"id\"" ]

let test_relation_literal_rejects_missing_type_expression () =
  rejects "relation { (id = 1) }"

let test_relation_literal_rejects_missing_brace_block () =
  rejects "relation (id: int64)"

(* The curly-brace form [{col: val}] was retired with the relation literal
   syntax flip. Confirm the parser now rejects it; pipeline-source position no
   longer accepts the curly form. *)
let test_relation_literal_curly_form_is_a_parse_error () = rejects "{id: 7}"

let test_relation_literal_followed_by_type_step () =
  parses
    "relation (id: int64, name: string) { (id = 1, name = \"alice\") } | type"
    (Ast.Type
       {
         input =
           Ast.Relation_literal
             { kind = id_int64_name_string_kind; rows = [ alice_row ] };
       })

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
      ( "type syntax",
        [
          Alcotest.test_case "parses a single type step" `Quick
            test_pipeline_parses_type_step;
          Alcotest.test_case
            "two type steps nest in the AST (Lower catches the nesting)" `Quick
            test_pipeline_parses_nested_type_step;
          Alcotest.test_case "[type] is a relation name as a pipeline head"
            `Quick test_pipeline_keyword_type_is_a_relation_name;
        ] );
      ( "unqualify syntax",
        [
          Alcotest.test_case "parses [users | unqualify]" `Quick
            test_pipeline_parses_unqualify_step;
          Alcotest.test_case
            "parses [users | join ... | unqualify] in pipeline order" `Quick
            test_pipeline_parses_unqualify_after_join;
        ] );
      ( "scalar literal source",
        [
          Alcotest.test_case "int64 literal parses as a pipeline source" `Quick
            test_scalar_literal_int64_parses_as_pipeline_source;
          Alcotest.test_case "negative int64 literal parses" `Quick
            test_scalar_literal_negative_int64_parses;
          Alcotest.test_case "string literal parses" `Quick
            test_scalar_literal_string_parses;
          Alcotest.test_case "[true] parses as a bool scalar literal" `Quick
            test_scalar_literal_true_parses_as_bool;
          Alcotest.test_case "[false] parses as a bool scalar literal" `Quick
            test_scalar_literal_false_parses_as_bool;
          Alcotest.test_case "tolerates surrounding whitespace" `Quick
            test_scalar_literal_tolerates_surrounding_whitespace;
          Alcotest.test_case
            "scalar literal feeds a [| type] step at pipeline-source position"
            `Quick test_scalar_literal_followed_by_type_step;
        ] );
      ( "row literal source",
        [
          Alcotest.test_case "empty row literal parses" `Quick
            test_row_literal_empty_parses;
          Alcotest.test_case "single-field row literal parses" `Quick
            test_row_literal_single_field_parses;
          Alcotest.test_case "multi-field row literal parses" `Quick
            test_row_literal_multiple_fields_parses;
          Alcotest.test_case "tolerates a trailing comma" `Quick
            test_row_literal_tolerates_trailing_comma;
          Alcotest.test_case "tolerates extra whitespace inside the literal"
            `Quick test_row_literal_tolerates_extra_whitespace;
          Alcotest.test_case "rejects a literal with a duplicate field" `Quick
            test_row_literal_rejects_duplicate_field;
          Alcotest.test_case "rejects a literal missing the equals sign" `Quick
            test_row_literal_rejects_missing_equals;
          Alcotest.test_case "rejects a literal with a missing value" `Quick
            test_row_literal_rejects_missing_value;
          Alcotest.test_case "rejects a literal with a leading comma" `Quick
            test_row_literal_rejects_leading_comma;
          Alcotest.test_case
            "row literal feeds a [| type] step at pipeline-source position"
            `Quick test_row_literal_followed_by_type_step;
          Alcotest.test_case "parses a qualified field name" `Quick
            test_row_literal_parses_qualified_field;
          Alcotest.test_case "parses mixed qualified and unqualified fields"
            `Quick test_row_literal_parses_mixed_qualified_and_unqualified;
          Alcotest.test_case
            "allows the same bare name under different qualifiers" `Quick
            test_row_literal_allows_same_bare_name_under_different_qualifiers;
          Alcotest.test_case "rejects two fields with the same qualified name"
            `Quick test_row_literal_rejects_duplicate_qualified_field;
        ] );
      ( "relation literal",
        [
          Alcotest.test_case "empty form parses with rows = []" `Quick
            test_relation_literal_empty_parses;
          Alcotest.test_case "single-row form parses" `Quick
            test_relation_literal_single_row_parses;
          Alcotest.test_case "multi-row form parses" `Quick
            test_relation_literal_multiple_rows_parses;
          Alcotest.test_case "tolerates a trailing comma after the last row"
            `Quick test_relation_literal_tolerates_trailing_comma;
          Alcotest.test_case "accepts a primary-key refinement on the kind"
            `Quick test_relation_literal_with_primary_key_refinement_parses;
          Alcotest.test_case "tolerates extra whitespace throughout" `Quick
            test_relation_literal_tolerates_extra_whitespace;
          Alcotest.test_case "rejects a row with a duplicate field name" `Quick
            test_relation_literal_rejects_duplicate_field_in_row;
          Alcotest.test_case "rejects the [relation] keyword without a type"
            `Quick test_relation_literal_rejects_missing_type_expression;
          Alcotest.test_case "rejects a typed literal without the brace block"
            `Quick test_relation_literal_rejects_missing_brace_block;
          Alcotest.test_case "typed literal feeds a [| type] step" `Quick
            test_relation_literal_followed_by_type_step;
          Alcotest.test_case "the retired [{col: val}] form is a parse error"
            `Quick test_relation_literal_curly_form_is_a_parse_error;
        ] );
      ( "insert sink syntax",
        [
          Alcotest.test_case "pipeline ending in a sink parses as Mutation"
            `Quick test_pipeline_ending_in_sink_parses_as_insert;
          Alcotest.test_case "pipeline without a sink parses as Query" `Quick
            test_pipeline_without_sink_parses_as_relation;
          Alcotest.test_case
            "upstream pipeline followed by a sink parses as Mutation" `Quick
            test_pipeline_with_upstream_pipeline_then_sink_parses_as_insert;
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
      ( "create table sink syntax (value-pipeline source)",
        [
          Alcotest.test_case
            "[<relation-literal> | create table <name>] parses as \
             Create_table_seeded"
            `Quick
            test_pipeline_create_table_seeded_with_relation_literal_source_parses;
          Alcotest.test_case
            "[<relation-name> | create table <name>] parses as \
             Create_table_seeded"
            `Quick
            test_pipeline_create_table_seeded_with_relation_name_source_parses;
          Alcotest.test_case
            "[<upstream-pipeline> | create table <name>] parses as \
             Create_table_seeded"
            `Quick test_pipeline_create_table_seeded_with_upstream_steps_parses;
          Alcotest.test_case "rejects a query operator after the sink" `Quick
            test_pipeline_create_table_sink_rejects_query_op_after_it;
          Alcotest.test_case "rejects the sink with nothing before it" `Quick
            test_pipeline_create_table_sink_rejects_with_nothing_before_it;
          Alcotest.test_case "rejects the sink without a target table" `Quick
            test_pipeline_create_table_sink_rejects_without_target_table;
          Alcotest.test_case "rejects the sink without the [table] keyword"
            `Quick test_pipeline_create_table_sink_rejects_without_table_keyword;
          Alcotest.test_case "rejects two create-table sinks in one pipeline"
            `Quick test_pipeline_create_table_sink_rejects_two_sinks;
          Alcotest.test_case
            "rejects [create table] followed by an [insert into] sink" `Quick
            test_pipeline_create_table_then_insert_into_is_rejected;
          Alcotest.test_case
            "rejects [insert into] followed by a [create table] sink" `Quick
            test_pipeline_insert_into_then_create_table_is_rejected;
        ] );
      ( "create table sink syntax (type-expression source)",
        [
          Alcotest.test_case
            "[<type-expr> | create table <name>] parses as Create_table_empty"
            `Quick
            test_pipeline_create_table_empty_with_simple_type_expression_parses;
          Alcotest.test_case
            "type expression with [primary key] refinement carries through"
            `Quick test_pipeline_create_table_empty_with_primary_key_parses;
          Alcotest.test_case
            "the type-expression form tolerates extra whitespace" `Quick
            test_pipeline_create_table_empty_tolerates_extra_whitespace;
          Alcotest.test_case
            "empty parens [()] dispatch to the value-literal branch" `Quick
            test_pipeline_empty_parens_dispatches_to_value_literal_branch;
          Alcotest.test_case "rejects a type expression piped into [restrict]"
            `Quick test_pipeline_type_expression_piped_into_restrict_is_rejected;
          Alcotest.test_case
            "rejects a type expression piped into [insert into]" `Quick
            test_pipeline_type_expression_piped_into_insert_into_is_rejected;
          Alcotest.test_case "rejects a bare type expression with no sink"
            `Quick test_pipeline_bare_type_expression_without_sink_is_rejected;
          Alcotest.test_case "rejects parens that mix [:] and [=] bindings"
            `Quick test_pipeline_parens_with_colon_and_equals_mixed_is_rejected;
        ] );
      ( "ddl syntax",
        [
          Alcotest.test_case ":list tables is no longer recognised" `Quick
            test_ddl_list_tables_is_no_longer_recognised;
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
          Alcotest.test_case ":drop table is no longer a recognised statement"
            `Quick test_ddl_drop_table_is_no_longer_recognised;
          Alcotest.test_case "bare [drop] in a pipeline is rejected" `Quick
            test_pipeline_keyword_drop_alone_is_rejected;
          Alcotest.test_case "[drop table <name>] parses as a Drop_table leaf"
            `Quick test_pipeline_drop_table_parses_as_drop_table_leaf;
          Alcotest.test_case
            "[drop table] tolerates extra whitespace between tokens" `Quick
            test_pipeline_drop_table_tolerates_extra_whitespace;
          Alcotest.test_case
            "[drop table <name> | <step>] parses with the step over the leaf"
            `Quick test_pipeline_drop_table_allows_downstream_pipeline_step;
          Alcotest.test_case
            "[drop <non-table-keyword>] in a pipeline is rejected" `Quick
            test_pipeline_drop_followed_by_non_table_keyword_is_rejected;
          Alcotest.test_case "[table] is a relation name in a pipeline" `Quick
            test_pipeline_keyword_table_is_a_relation_name;
          Alcotest.test_case ":describe is no longer a recognised statement"
            `Quick test_ddl_describe_is_no_longer_recognised;
          Alcotest.test_case ":create table is no longer a recognised statement"
            `Quick test_ddl_create_table_is_no_longer_recognised;
          Alcotest.test_case "[create] is a relation name in a pipeline" `Quick
            test_pipeline_keyword_create_is_a_relation_name;
          Alcotest.test_case "bare [catalog] parses as a Catalog_source leaf"
            `Quick test_pipeline_bare_catalog_parses_as_catalog_source;
          Alcotest.test_case "[catalog] tolerates surrounding whitespace" `Quick
            test_pipeline_catalog_tolerates_surrounding_whitespace;
          Alcotest.test_case
            "[catalog | <step>] parses with the step over the leaf" `Quick
            test_pipeline_catalog_allows_downstream_pipeline_step;
          Alcotest.test_case "[| tables] wraps the upstream pipeline in Tables"
            `Quick test_pipeline_tables_step_wraps_upstream;
          Alcotest.test_case "[catalog | tables | type] composes left-to-right"
            `Quick test_pipeline_tables_then_type_composes;
        ] );
    ]
