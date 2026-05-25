(** Tests for [Parser]. *)

open Dovetail_surface_ra
open Test_helpers
module Ddl = Dovetail_ddl
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

let ast_program_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<ast-program>")) ( = )

(* Wraps the expected [Ast.t] in [Ast.Pipeline] before comparing against the
   parser's [Ast.program] output. The sink-production tests below build an
   [Ast.Insert] inside the pipeline using {!parses_plan}; the DDL tests use
   [parses_program] to assert against an [Ast.Ddl] directly. *)
let parses input expected_inner_ast =
  match Parser.parse input with
  | Ok actual_program ->
      Alcotest.(check ast_program_testable)
        (Printf.sprintf "%S parses" input)
        (Ast.Pipeline expected_inner_ast) actual_program
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

(* The DDL sigil. A leading [:] (after any optional whitespace) marks a
   DDL statement. The sigil is recognised only at the top of input -- a
   [:] inside a pipeline is a parse error rather than an embedded DDL
   statement. *)

let test_ddl_list_tables_parses () =
  parses_program ":list tables" (Ast.Ddl Ddl.Statement.List_tables)

let test_ddl_list_tables_tolerates_leading_whitespace () =
  parses_program "   :list tables" (Ast.Ddl Ddl.Statement.List_tables)

let test_ddl_list_tables_tolerates_whitespace_after_sigil () =
  parses_program ":   list tables" (Ast.Ddl Ddl.Statement.List_tables)

let test_ddl_list_tables_tolerates_extra_whitespace_between_keywords () =
  parses_program ":list    tables" (Ast.Ddl Ddl.Statement.List_tables)

let test_ddl_list_tables_tolerates_trailing_whitespace () =
  parses_program ":list tables    " (Ast.Ddl Ddl.Statement.List_tables)

let test_ddl_drop_table_parses () =
  parses_program ":drop table users"
    (Ast.Ddl (Ddl.Statement.Drop_table { table_name = "users" }))

let test_ddl_drop_table_tolerates_extra_whitespace () =
  parses_program ":drop    table    users"
    (Ast.Ddl (Ddl.Statement.Drop_table { table_name = "users" }))

let test_ddl_drop_table_accepts_identifier_with_digits () =
  parses_program ":drop table users_2"
    (Ast.Ddl (Ddl.Statement.Drop_table { table_name = "users_2" }))

let test_ddl_drop_table_rejects_missing_target () = rejects ":drop table"
let test_ddl_drop_table_rejects_missing_table_keyword () = rejects ":drop users"

let test_ddl_drop_table_rejects_quoted_name () =
  (* Identifiers are bare; a string literal is not a valid target. *)
  rejects ":drop table \"users\""

let test_ddl_drop_table_rejects_trailing_garbage () =
  rejects ":drop table users xyz"

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

(* [:create table <name> (col: kind, ...) primary key
   (col, ...)] parses to [Statement.Create_table { table_name; fields;
   primary_key }]. Kind names are resolved at parse time to
   [Scalar.kind]; unknown kind names raise a parse error. Whitespace
   and trailing commas are flexible inside the parentheses, matching
   the canonical printer's output so [parse (format s) = Ok (Ddl s)]
   holds for hand-built [Create_table] values. *)

let test_ddl_create_table_int64_pk_parses () =
  parses_program ":create table widgets (id: Int64) primary key (id)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Int64 } ];
            primary_key = [ "id" ];
          }))

let test_ddl_create_table_string_pk_parses () =
  parses_program ":create table widgets (name: String) primary key (name)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "name"; kind = String } ];
            primary_key = [ "name" ];
          }))

let test_ddl_create_table_bool_pk_parses () =
  parses_program ":create table widgets (active: Bool) primary key (active)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "active"; kind = Bool } ];
            primary_key = [ "active" ];
          }))

let test_ddl_create_table_compound_pk_parses () =
  parses_program
    ":create table pairs (left: Int64, right: Int64) primary key (left, right)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "pairs";
            fields =
              [
                { name = "left"; kind = Int64 };
                { name = "right"; kind = Int64 };
              ];
            primary_key = [ "left"; "right" ];
          }))

(* Trailing commas in both the column list and the primary key list are
   tolerated. The canonical printer always emits a trailing comma on the
   column list, so this directly supports the round-trip property. *)
let test_ddl_create_table_trailing_comma_in_column_list_parses () =
  parses_program ":create table widgets (id: Int64,) primary key (id)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Int64 } ];
            primary_key = [ "id" ];
          }))

let test_ddl_create_table_trailing_comma_in_primary_key_list_parses () =
  parses_program ":create table widgets (id: Int64) primary key (id,)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Int64 } ];
            primary_key = [ "id" ];
          }))

(* The canonical multi-line form from the design doc parses identically
   to the single-line equivalent -- whitespace inside parens is flexible. *)
let test_ddl_create_table_multiline_canonical_form_parses () =
  parses_program
    ":create table users (\n\
    \  id: Int64,\n\
    \  name: String,\n\
    \  email: String,\n\
    \  active: Bool,\n\
     ) primary key (id)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "users";
            fields =
              [
                { name = "id"; kind = Int64 };
                { name = "name"; kind = String };
                { name = "email"; kind = String };
                { name = "active"; kind = Bool };
              ];
            primary_key = [ "id" ];
          }))

let test_ddl_create_table_rejects_unknown_kind () =
  rejects ":create table widgets (id: Int32) primary key (id)"

(* An empty column list parses to a [Create_table] with [fields = []].
   The grammar accepts it so the validator can produce a friendly
   [DDL: create table ...: column list is empty] error rather than a
   raw [parse error: satisfy: ...] from the angstrom field combinator. *)
let test_ddl_create_table_empty_column_list_parses_with_empty_fields () =
  parses_program ":create table widgets () primary key (id)"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          { table_name = "widgets"; fields = []; primary_key = [ "id" ] }))

(* An empty primary-key list parses to a [Create_table] with
   [primary_key = []]. Same rationale as the empty column list: the
   validator's [primary key is empty] message is the user-friendly
   path for this shape. *)
let test_ddl_create_table_empty_primary_key_list_parses_with_empty_primary_key
    () =
  parses_program ":create table widgets (id: Int64) primary key ()"
    (Ast.Ddl
       (Ddl.Statement.Create_table
          {
            table_name = "widgets";
            fields = [ { name = "id"; kind = Int64 } ];
            primary_key = [];
          }))

let test_ddl_create_table_rejects_missing_primary_key_clause () =
  rejects ":create table widgets (id: Int64)"

let test_ddl_create_table_rejects_missing_colon_in_field () =
  rejects ":create table widgets (id Int64) primary key (id)"

let test_ddl_create_table_rejects_missing_kind () =
  rejects ":create table widgets (id:) primary key (id)"

let test_ddl_create_table_rejects_missing_table_name () =
  rejects ":create table (id: Int64) primary key (id)"

(* The DDL keyword [create] is not globally reserved -- matches the
   [list] / [tables] / [drop] / [table] cases above. *)
let test_pipeline_keyword_create_is_a_relation_name () =
  parses "create" (Ast.Relation_name "create")

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
          Alcotest.test_case ":drop table <name> parses to Ddl Drop_table"
            `Quick test_ddl_drop_table_parses;
          Alcotest.test_case
            ":drop table tolerates extra whitespace between keywords" `Quick
            test_ddl_drop_table_tolerates_extra_whitespace;
          Alcotest.test_case
            ":drop table accepts an identifier with digits and underscores"
            `Quick test_ddl_drop_table_accepts_identifier_with_digits;
          Alcotest.test_case ":drop table without a target rejects" `Quick
            test_ddl_drop_table_rejects_missing_target;
          Alcotest.test_case ":drop without the table keyword rejects" `Quick
            test_ddl_drop_table_rejects_missing_table_keyword;
          Alcotest.test_case ":drop table with a quoted name rejects" `Quick
            test_ddl_drop_table_rejects_quoted_name;
          Alcotest.test_case ":drop table with trailing garbage rejects" `Quick
            test_ddl_drop_table_rejects_trailing_garbage;
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
          Alcotest.test_case
            ":create table single-column Int64 PK parses to Ddl Create_table"
            `Quick test_ddl_create_table_int64_pk_parses;
          Alcotest.test_case
            ":create table single-column String PK parses to Ddl Create_table"
            `Quick test_ddl_create_table_string_pk_parses;
          Alcotest.test_case
            ":create table single-column Bool PK parses to Ddl Create_table"
            `Quick test_ddl_create_table_bool_pk_parses;
          Alcotest.test_case ":create table compound PK parses" `Quick
            test_ddl_create_table_compound_pk_parses;
          Alcotest.test_case
            ":create table tolerates a trailing comma in the column list" `Quick
            test_ddl_create_table_trailing_comma_in_column_list_parses;
          Alcotest.test_case
            ":create table tolerates a trailing comma in the primary key list"
            `Quick
            test_ddl_create_table_trailing_comma_in_primary_key_list_parses;
          Alcotest.test_case
            ":create table parses the canonical multi-line form" `Quick
            test_ddl_create_table_multiline_canonical_form_parses;
          Alcotest.test_case ":create table with an unknown kind rejects" `Quick
            test_ddl_create_table_rejects_unknown_kind;
          Alcotest.test_case
            ":create table with an empty column list parses to fields = []"
            `Quick
            test_ddl_create_table_empty_column_list_parses_with_empty_fields;
          Alcotest.test_case
            ":create table with an empty primary key list parses to \
             primary_key = []"
            `Quick
            test_ddl_create_table_empty_primary_key_list_parses_with_empty_primary_key;
          Alcotest.test_case
            ":create table without a primary key clause rejects" `Quick
            test_ddl_create_table_rejects_missing_primary_key_clause;
          Alcotest.test_case
            ":create table missing the colon in a field rejects" `Quick
            test_ddl_create_table_rejects_missing_colon_in_field;
          Alcotest.test_case ":create table missing a field kind rejects" `Quick
            test_ddl_create_table_rejects_missing_kind;
          Alcotest.test_case ":create table without a table name rejects" `Quick
            test_ddl_create_table_rejects_missing_table_name;
          Alcotest.test_case "[create] is a relation name in a pipeline" `Quick
            test_pipeline_keyword_create_is_a_relation_name;
        ] );
    ]
