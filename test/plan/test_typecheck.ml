(** Tests for [Typecheck].

    The pass walks a [Logical.t] against a snapshotted catalog and accumulates
    structured errors. Tests assert both the structured variant and its rendered
    form for each error class. *)

open Dovetail_plan
module Catalog = Dovetail_core.Catalog
module Expression = Dovetail_core.Expression
module Scalar = Dovetail_core.Scalar
module Relation = Dovetail_core.Relation
module Row = Dovetail_core.Row

let empty_catalog : Catalog.kind = { relation_kinds = [] }

let logical_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical>")) ( = )

let error_list_testable =
  Alcotest.testable
    (Fmt.of_to_string (fun errors ->
         String.concat " | " (List.map Typecheck.render errors)))
    ( = )

(* Three columns, all qualified to "orders". Used as a stand-in target
   schema for the Insert tests below. *)
let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* Build an [Insert] of a [Relation_literal] whose [kind] is derived from the
   supplied [pairs] (one per column). Values are placeholders -- this slice
   only cares about column-name agreement. *)
let insert_literal ~table ~pairs : Logical.t =
  let row_kind =
    List.map
      (fun (name, value) : Row.field ->
        { name; kind = Scalar.kind_of value; qualifier = None })
      pairs
  in
  let row = List.map snd pairs in
  Insert
    {
      table;
      source =
        Relation_literal
          { kind = { row_kind; refinements = [] }; rows = [ row ] };
    }

let orders_catalog : Catalog.kind =
  { relation_kinds = [ ("orders", orders_kind) ] }

let test_no_op_pass_returns_input_unchanged () =
  (* The catalog has to know about the scanned table for the pass to be a
     no-op now that Typecheck checks unknown sources. *)
  let users_kind : Relation.kind =
    {
      row_kind = [ { name = "id"; kind = Int64; qualifier = Some "users" } ];
      refinements = [];
    }
  in
  let catalog : Catalog.kind = { relation_kinds = [ ("users", users_kind) ] } in
  let plan : Logical.t = Scan { table = "users" } in
  match Typecheck.typecheck ~catalog plan with
  | Ok result -> Alcotest.(check logical_testable) "plan unchanged" plan result
  | Error _ -> Alcotest.fail "expected Ok with no errors"

let test_insert_with_missing_columns_reports_structured_error () =
  let plan =
    insert_literal ~table:"orders" ~pairs:[ ("id", Scalar.Int64 9L) ]
    (* description and amount missing. *)
  in
  let expected : Typecheck.error list =
    [
      Insert_column_mismatch
        {
          table_name = "orders";
          missing = [ "description"; "amount" ];
          extra = [];
        };
    ]
  in
  match Typecheck.typecheck ~catalog:orders_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Insert_column_mismatch error"
  | Error errors ->
      Alcotest.(check error_list_testable) "structured mismatch" expected errors

let test_insert_with_missing_columns_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Insert_column_mismatch
      {
        table_name = "orders";
        missing = [ "description"; "amount" ];
        extra = [];
      }
  in
  Alcotest.(check string)
    "rendered missing-columns error"
    "Insert: into \"orders\": missing column(s): description, amount"
    (Typecheck.render error)

let test_insert_with_unknown_columns_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Insert_column_mismatch
      { table_name = "orders"; missing = []; extra = [ "colour" ] }
  in
  Alcotest.(check string)
    "rendered unknown-columns error"
    "Insert: into \"orders\": unknown column(s): colour"
    (Typecheck.render error)

let test_insert_with_both_missing_and_unknown_renders_both_halves () =
  let error : Typecheck.error =
    Insert_column_mismatch
      { table_name = "orders"; missing = [ "amount" ]; extra = [ "colour" ] }
  in
  Alcotest.(check string)
    "rendered combined error"
    "Insert: into \"orders\": missing column(s): amount; unknown column(s): \
     colour"
    (Typecheck.render error)

let test_insert_into_unknown_table_reports_structured_error () =
  let plan =
    insert_literal ~table:"widgets" ~pairs:[ ("id", Scalar.Int64 1L) ]
  in
  let expected : Typecheck.error list =
    [ Unknown_table { operator = "Insert"; table_name = "widgets" } ]
  in
  match Typecheck.typecheck ~catalog:orders_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Unknown_table error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured unknown insert target" expected errors

let test_unknown_table_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Unknown_table { operator = "Insert"; table_name = "widgets" }
  in
  Alcotest.(check string)
    "rendered insert-target unknown-table error"
    "Insert: into \"widgets\": unknown table" (Typecheck.render error)

let test_scan_of_unknown_table_reports_structured_error () =
  let plan : Logical.t = Scan { table = "ghost" } in
  let expected : Typecheck.error list =
    [ Unknown_table { operator = "Scan"; table_name = "ghost" } ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Unknown_table error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured unknown scan target" expected errors

let test_unknown_table_renders_with_scan_prefix () =
  let error : Typecheck.error =
    Unknown_table { operator = "Scan"; table_name = "ghost" }
  in
  Alcotest.(check string)
    "rendered scan unknown-table error" "Scan: unknown table \"ghost\""
    (Typecheck.render error)

let test_insert_with_kind_mismatch_reports_structured_error () =
  let plan =
    insert_literal ~table:"orders"
      ~pairs:
        [
          ("id", Scalar.Int64 9L);
          ("description", Scalar.String "Pretzel");
          (* amount expects Int64; supply a String. *)
          ("amount", Scalar.String "nine");
        ]
  in
  let expected : Typecheck.error list =
    [
      Insert_kind_mismatch
        {
          table_name = "orders";
          column = "amount";
          expected = Int64;
          actual = String;
        };
    ]
  in
  match Typecheck.typecheck ~catalog:orders_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Insert_kind_mismatch error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured kind mismatch" expected errors

let test_insert_kind_mismatch_renders_with_insert_prefix () =
  let error : Typecheck.error =
    Insert_kind_mismatch
      {
        table_name = "orders";
        column = "amount";
        expected = Int64;
        actual = String;
      }
  in
  Alcotest.(check string)
    "rendered kind-mismatch error"
    "Insert: into \"orders\": column \"amount\" expects Int64, got String"
    (Typecheck.render error)

(* A two-column literal used as the input of [Restrict] / [Project] tests
   below. Kind is declared inline so the typecheck walker can derive the
   input row kind without a catalog lookup. *)
let two_column_literal : Logical.t =
  Relation_literal
    {
      kind =
        {
          row_kind =
            [
              { name = "id"; kind = Int64; qualifier = None };
              { name = "description"; kind = String; qualifier = None };
            ];
          refinements = [];
        };
      rows = [];
    }

let two_column_row_kind : Row.kind =
  [
    { name = "id"; kind = Int64; qualifier = None };
    { name = "description"; kind = String; qualifier = None };
  ]

let test_restrict_with_unresolved_column_reports_structured_error () =
  let predicate : Expression.t =
    Compare
      {
        left = Column { qualifier = None; name = "missing" };
        op = Equal;
        right = Literal (Scalar.Int64 1L);
      }
  in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  let expected : Typecheck.error list =
    [
      Unresolved_column
        {
          column_reference = { qualifier = None; name = "missing" };
          available_row_kind = two_column_row_kind;
          operator = "Restrict";
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Unresolved_column error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured unresolved" expected errors

let test_restrict_unknown_column_renders_with_restrict_prefix () =
  let error : Typecheck.error =
    Unresolved_column
      {
        column_reference = { qualifier = None; name = "missing" };
        available_row_kind = two_column_row_kind;
        operator = "Restrict";
      }
  in
  Alcotest.(check string)
    "rendered unknown column" "Restrict: unknown column \"missing\""
    (Typecheck.render error)

let test_restrict_qualified_unknown_renders_dotted () =
  let error : Typecheck.error =
    Unresolved_column
      {
        column_reference = { qualifier = Some "users"; name = "id" };
        available_row_kind = two_column_row_kind;
        operator = "Restrict";
      }
  in
  Alcotest.(check string)
    "rendered qualified unknown" "Restrict: unknown column \"users.id\""
    (Typecheck.render error)

let test_restrict_with_ambiguous_bare_reference_reports_structured_error () =
  (* Cross-product produces a row kind with [id] in both qualifiers; a bare
     [Column { name = "id" }] then refers to both. *)
  let left : Logical.t =
    Relation_literal
      {
        kind =
          {
            row_kind =
              [ { name = "id"; kind = Int64; qualifier = Some "left" } ];
            refinements = [];
          };
        rows = [];
      }
  in
  let right : Logical.t =
    Relation_literal
      {
        kind =
          {
            row_kind =
              [ { name = "id"; kind = Int64; qualifier = Some "right" } ];
            refinements = [];
          };
        rows = [];
      }
  in
  let predicate : Expression.t =
    Compare
      {
        left = Column { qualifier = None; name = "id" };
        op = Equal;
        right = Literal (Scalar.Int64 1L);
      }
  in
  let plan : Logical.t =
    Restrict { input = CrossProduct { left; right }; predicate }
  in
  let expected : Typecheck.error list =
    [
      Unresolved_column
        {
          column_reference = { qualifier = None; name = "id" };
          available_row_kind =
            [
              { name = "id"; kind = Int64; qualifier = Some "left" };
              { name = "id"; kind = Int64; qualifier = Some "right" };
            ];
          operator = "Restrict";
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Unresolved_column error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured ambiguous" expected errors

let test_restrict_with_compare_kind_mismatch_reports_structured_error () =
  let predicate : Expression.t =
    Compare
      {
        left = Column { qualifier = None; name = "description" };
        op = Equal;
        right = Literal (Scalar.Int64 1L);
      }
  in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  let expected : Typecheck.error list =
    [
      Compare_kind_mismatch
        {
          operator = "Restrict";
          left = Column { qualifier = None; name = "description" };
          left_kind = String;
          right = Literal (Scalar.Int64 1L);
          right_kind = Int64;
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected a Compare_kind_mismatch error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured kind mismatch" expected errors

let test_compare_kind_mismatch_renders_with_operator_prefix () =
  let error : Typecheck.error =
    Compare_kind_mismatch
      {
        operator = "Restrict";
        left = Column { qualifier = None; name = "description" };
        left_kind = String;
        right = Literal (Scalar.Int64 1L);
        right_kind = Int64;
      }
  in
  Alcotest.(check string)
    "rendered compare mismatch"
    "Restrict: type mismatch: column \"description\" is String, literal Int64 \
     is Int64"
    (Typecheck.render error)

let test_restrict_with_ordering_on_bool_reports_structured_error () =
  (* Two-column literal with a Bool column so the ordering check fires
     without a kind-mismatch error masking it. *)
  let input : Logical.t =
    Relation_literal
      {
        kind =
          {
            row_kind =
              [
                { name = "active"; kind = Bool; qualifier = None };
                { name = "also_active"; kind = Bool; qualifier = None };
              ];
            refinements = [];
          };
        rows = [];
      }
  in
  let predicate : Expression.t =
    Compare
      {
        left = Column { qualifier = None; name = "active" };
        op = Greater;
        right = Column { qualifier = None; name = "also_active" };
      }
  in
  let plan : Logical.t = Restrict { input; predicate } in
  let expected : Typecheck.error list =
    [
      Ordering_operator_on_unordered_kind
        { operator = "Restrict"; comparison_op = Greater; kind = Bool };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ ->
      Alcotest.fail "expected an Ordering_operator_on_unordered_kind error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured ordering error" expected errors

let test_ordering_on_bool_renders_with_operator_prefix () =
  let error : Typecheck.error =
    Ordering_operator_on_unordered_kind
      { operator = "Restrict"; comparison_op = Greater; kind = Bool }
  in
  Alcotest.(check string)
    "rendered ordering error"
    "Restrict: ordering operator > is not defined for Bool"
    (Typecheck.render error)

let test_restrict_skips_ordering_check_when_kinds_disagree () =
  (* When the two sides of a Compare have different kinds, the
     mismatch error is enough; we don't also emit an ordering error. *)
  let predicate : Expression.t =
    Compare
      {
        left = Column { qualifier = None; name = "description" };
        op = Greater;
        right = Literal (Scalar.Int64 1L);
      }
  in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected one Compare_kind_mismatch error"
  | Error errors ->
      let count = List.length errors in
      Alcotest.(check int) "exactly one error" 1 count

let test_restrict_with_non_bool_predicate_reports_structured_error () =
  (* A bare [Column "id"] predicate evaluates to Int64; the predicate
     position requires Bool. *)
  let predicate : Expression.t = Column { qualifier = None; name = "id" } in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  let expected : Typecheck.error list =
    [
      Predicate_not_boolean
        { operator = "Restrict"; expression = predicate; actual_kind = Int64 };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected a Predicate_not_boolean error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured predicate kind" expected errors

let test_predicate_not_boolean_renders_with_operator_prefix () =
  let error : Typecheck.error =
    Predicate_not_boolean
      {
        operator = "Restrict";
        expression = Column { qualifier = None; name = "id" };
        actual_kind = Int64;
      }
  in
  Alcotest.(check string)
    "rendered predicate-kind error"
    "Restrict: predicate position requires Bool, got Int64"
    (Typecheck.render error)

let test_restrict_with_non_bool_and_operand_reports_structured_error () =
  (* And requires Bool on both sides; supplying [id] (Int64) on the left
     and a Bool literal on the right fires one [Boolean_operand_required]. *)
  let left_operand : Expression.t = Column { qualifier = None; name = "id" } in
  let predicate : Expression.t =
    And (left_operand, Literal (Scalar.Bool true))
  in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  let expected : Typecheck.error list =
    [
      Boolean_operand_required
        {
          operator = "Restrict";
          logical_op = "and";
          operand = left_operand;
          operand_kind = Int64;
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected a Boolean_operand_required error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured and-operand kind" expected errors

let test_boolean_operand_required_and_renders_with_operator_prefix () =
  let error : Typecheck.error =
    Boolean_operand_required
      {
        operator = "Restrict";
        logical_op = "and";
        operand = Column { qualifier = None; name = "id" };
        operand_kind = Int64;
      }
  in
  Alcotest.(check string)
    "rendered and-operand error"
    "Restrict: and requires Bool operands: column \"id\" is Int64"
    (Typecheck.render error)

let test_restrict_with_non_bool_not_operand_reports_structured_error () =
  let operand : Expression.t = Column { qualifier = None; name = "id" } in
  let predicate : Expression.t = Not operand in
  let plan : Logical.t = Restrict { input = two_column_literal; predicate } in
  let expected : Typecheck.error list =
    [
      Boolean_operand_required
        {
          operator = "Restrict";
          logical_op = "not";
          operand;
          operand_kind = Int64;
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected a Boolean_operand_required error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured not-operand kind" expected errors

let test_boolean_operand_required_not_renders_with_operator_prefix () =
  let error : Typecheck.error =
    Boolean_operand_required
      {
        operator = "Restrict";
        logical_op = "not";
        operand = Column { qualifier = None; name = "id" };
        operand_kind = Int64;
      }
  in
  Alcotest.(check string)
    "rendered not-operand error"
    "Restrict: not requires a Bool operand: column \"id\" is Int64"
    (Typecheck.render error)

let test_project_with_unresolved_column_reports_structured_error () =
  let plan : Logical.t =
    Project
      {
        input = two_column_literal;
        columns = [ { qualifier = None; name = "missing" } ];
      }
  in
  let expected : Typecheck.error list =
    [
      Unresolved_column
        {
          column_reference = { qualifier = None; name = "missing" };
          available_row_kind = two_column_row_kind;
          operator = "Project";
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected an Unresolved_column error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured unresolved project" expected errors

let test_project_emits_one_error_per_unresolved_column () =
  let plan : Logical.t =
    Project
      {
        input = two_column_literal;
        columns =
          [
            { qualifier = None; name = "id" };
            { qualifier = None; name = "missing_one" };
            { qualifier = None; name = "missing_two" };
          ];
      }
  in
  let expected : Typecheck.error list =
    [
      Unresolved_column
        {
          column_reference = { qualifier = None; name = "missing_one" };
          available_row_kind = two_column_row_kind;
          operator = "Project";
        };
      Unresolved_column
        {
          column_reference = { qualifier = None; name = "missing_two" };
          available_row_kind = two_column_row_kind;
          operator = "Project";
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected two Unresolved_column errors"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "two structured errors" expected errors

let test_project_with_duplicate_column_reports_structured_error () =
  let plan : Logical.t =
    Project
      {
        input = two_column_literal;
        columns =
          [
            { qualifier = None; name = "id" }; { qualifier = None; name = "id" };
          ];
      }
  in
  let expected : Typecheck.error list =
    [
      Projection_duplicate_column
        {
          operator = "Project";
          column_reference = { qualifier = None; name = "id" };
        };
    ]
  in
  match Typecheck.typecheck ~catalog:empty_catalog plan with
  | Ok _ -> Alcotest.fail "expected a Projection_duplicate_column error"
  | Error errors ->
      Alcotest.(check error_list_testable)
        "structured duplicate" expected errors

let test_projection_duplicate_renders_with_project_prefix () =
  let error : Typecheck.error =
    Projection_duplicate_column
      {
        operator = "Project";
        column_reference = { qualifier = None; name = "id" };
      }
  in
  Alcotest.(check string)
    "rendered duplicate" "Project: duplicate column \"id\""
    (Typecheck.render error)

let test_project_unknown_column_renders_with_project_prefix () =
  let error : Typecheck.error =
    Unresolved_column
      {
        column_reference = { qualifier = None; name = "missing" };
        available_row_kind = two_column_row_kind;
        operator = "Project";
      }
  in
  Alcotest.(check string)
    "rendered project unknown" "Project: unknown column \"missing\""
    (Typecheck.render error)

let test_restrict_ambiguous_bare_renders_with_match_list () =
  let error : Typecheck.error =
    Unresolved_column
      {
        column_reference = { qualifier = None; name = "id" };
        available_row_kind =
          [
            { name = "id"; kind = Int64; qualifier = Some "left" };
            { name = "id"; kind = Int64; qualifier = Some "right" };
          ];
        operator = "Restrict";
      }
  in
  Alcotest.(check string)
    "rendered ambiguous"
    "Restrict: ambiguous column reference \"id\": matches \"left.id\" and \
     \"right.id\""
    (Typecheck.render error)

let () =
  Alcotest.run "typecheck"
    [
      ( "no-op pass",
        [
          Alcotest.test_case "returns input unchanged" `Quick
            test_no_op_pass_returns_input_unchanged;
        ] );
      ( "insert column mismatch",
        [
          Alcotest.test_case "missing columns produce a structured error" `Quick
            test_insert_with_missing_columns_reports_structured_error;
          Alcotest.test_case "missing columns render with Insert prefix" `Quick
            test_insert_with_missing_columns_renders_with_insert_prefix;
          Alcotest.test_case "unknown columns render with Insert prefix" `Quick
            test_insert_with_unknown_columns_renders_with_insert_prefix;
          Alcotest.test_case "missing and unknown render together" `Quick
            test_insert_with_both_missing_and_unknown_renders_both_halves;
        ] );
      ( "unknown table",
        [
          Alcotest.test_case
            "Insert into an unknown table produces a structured error" `Quick
            test_insert_into_unknown_table_reports_structured_error;
          Alcotest.test_case "Insert unknown-table renders with Insert prefix"
            `Quick test_unknown_table_renders_with_insert_prefix;
          Alcotest.test_case
            "Scan of an unknown table produces a structured error" `Quick
            test_scan_of_unknown_table_reports_structured_error;
          Alcotest.test_case "Scan unknown-table renders with Scan prefix"
            `Quick test_unknown_table_renders_with_scan_prefix;
        ] );
      ( "restrict unresolved column",
        [
          Alcotest.test_case "unknown column produces a structured error" `Quick
            test_restrict_with_unresolved_column_reports_structured_error;
          Alcotest.test_case "unknown column renders with Restrict prefix"
            `Quick test_restrict_unknown_column_renders_with_restrict_prefix;
          Alcotest.test_case "qualified unknown renders dotted" `Quick
            test_restrict_qualified_unknown_renders_dotted;
          Alcotest.test_case
            "ambiguous bare reference produces a structured error" `Quick
            test_restrict_with_ambiguous_bare_reference_reports_structured_error;
          Alcotest.test_case "ambiguous bare reference renders with match list"
            `Quick test_restrict_ambiguous_bare_renders_with_match_list;
        ] );
      ( "project unresolved column",
        [
          Alcotest.test_case "unknown column produces a structured error" `Quick
            test_project_with_unresolved_column_reports_structured_error;
          Alcotest.test_case "every unresolved column produces its own error"
            `Quick test_project_emits_one_error_per_unresolved_column;
          Alcotest.test_case "unknown column renders with Project prefix" `Quick
            test_project_unknown_column_renders_with_project_prefix;
          Alcotest.test_case "duplicate column produces a structured error"
            `Quick test_project_with_duplicate_column_reports_structured_error;
          Alcotest.test_case "duplicate column renders with Project prefix"
            `Quick test_projection_duplicate_renders_with_project_prefix;
        ] );
      ( "restrict compare kind validation",
        [
          Alcotest.test_case "kind mismatch produces a structured error" `Quick
            test_restrict_with_compare_kind_mismatch_reports_structured_error;
          Alcotest.test_case "kind mismatch renders with operator prefix" `Quick
            test_compare_kind_mismatch_renders_with_operator_prefix;
          Alcotest.test_case "ordering on Bool produces a structured error"
            `Quick test_restrict_with_ordering_on_bool_reports_structured_error;
          Alcotest.test_case "ordering error renders with operator prefix"
            `Quick test_ordering_on_bool_renders_with_operator_prefix;
          Alcotest.test_case "kind mismatch alone suppresses the ordering check"
            `Quick test_restrict_skips_ordering_check_when_kinds_disagree;
        ] );
      ( "restrict predicate kind",
        [
          Alcotest.test_case "non-Bool predicate produces a structured error"
            `Quick
            test_restrict_with_non_bool_predicate_reports_structured_error;
          Alcotest.test_case "predicate-kind error renders with operator prefix"
            `Quick test_predicate_not_boolean_renders_with_operator_prefix;
        ] );
      ( "boolean operand kind",
        [
          Alcotest.test_case "non-Bool and operand produces a structured error"
            `Quick
            test_restrict_with_non_bool_and_operand_reports_structured_error;
          Alcotest.test_case "and-operand error renders with operator prefix"
            `Quick
            test_boolean_operand_required_and_renders_with_operator_prefix;
          Alcotest.test_case "non-Bool not operand produces a structured error"
            `Quick
            test_restrict_with_non_bool_not_operand_reports_structured_error;
          Alcotest.test_case "not-operand error renders with operator prefix"
            `Quick
            test_boolean_operand_required_not_renders_with_operator_prefix;
        ] );
      ( "insert kind mismatch",
        [
          Alcotest.test_case "mismatched value kind produces a structured error"
            `Quick test_insert_with_kind_mismatch_reports_structured_error;
          Alcotest.test_case "kind mismatch renders with Insert prefix" `Quick
            test_insert_kind_mismatch_renders_with_insert_prefix;
        ] );
    ]
