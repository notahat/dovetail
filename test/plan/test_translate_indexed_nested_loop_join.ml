(** Tests for [Translate]'s [IndexedNestedLoopJoin] rewrite.

    The rewrite widens the existing
    [Restrict (CrossProduct (left, right), predicate)] arm: when one side is a
    bare [Scan] whose catalog schema has a single-column [Int64] primary key,
    and the predicate contains a cross-side equality naming that PK column on
    exactly one side, translate emits an [IndexedNestedLoopJoin] streaming the
    other side. The predicate is flattened into a conjunct list; the first
    PK-equality conjunct is folded into the indexed join, and any remaining
    conjuncts become a wrapping [Filter]. Every other shape (no matching PK,
    non-bare scans, no PK-equality conjunct) falls through to
    {!Physical.NestedLoopJoin}.

    Each test builds its own in-test catalog so the unit tests don't need a live
    LMDB environment; pipeline-level integration tests live in
    [test_pipeline.ml]. *)

open Dovetail_plan
open Test_helpers
module Relation = Dovetail_core.Relation
module Scalar = Dovetail_core.Scalar

(* A users kind with a single int64 primary key, identical to
   [Fixture.users_kind] but rebuilt in-test so unit tests don't need
   the LMDB fixture. *)
let users_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* An orders kind with a single int64 primary key. Same shape as the
   fixture's, but locally defined for unit-test independence. *)
let orders_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* A second table whose primary key is also a single Int64 [id]. Used to
   build the "both sides qualify" tiebreaker case: [users.id = admins.id]
   has the PK column referenced on both sides of the equality. *)
let admins_kind : Relation.kind =
  {
    row_kind =
      [
        { name = "id"; kind = Int64; qualifier = Some "admins" };
        { name = "level"; kind = Int64; qualifier = Some "admins" };
      ];
    refinements = [ Primary_key [ "id" ] ];
  }

(* A catalog that knows about [users] and [orders]. The canonical test
   case for the rewrite uses this. *)
let users_and_orders_catalog table_name =
  match table_name with
  | "users" -> Some users_kind
  | "orders" -> Some orders_kind
  | _ -> None

(* A catalog that knows about [users] and [admins] -- both with PK [id]
   in the same kind. Drives the both-sides-qualify tiebreaker test. *)
let users_and_admins_catalog table_name =
  match table_name with
  | "users" -> Some users_kind
  | "admins" -> Some admins_kind
  | _ -> None

let users_id_column =
  qualified_row_column_reference ~qualifier:"users" ~name:"id"

let orders_user_id_column =
  qualified_row_column_reference ~qualifier:"orders" ~name:"user_id"

let admins_id_column =
  qualified_row_column_reference ~qualifier:"admins" ~name:"id"

let users_id_equals_orders_user_id =
  expression_compare ~left:(Column users_id_column) ~op:Equal
    ~right:(Column orders_user_id_column)

let users_join_orders_on_pk_equality : Logical.t =
  Restrict
    {
      input =
        CrossProduct
          { left = Scan { table = "users" }; right = Scan { table = "orders" } };
      predicate = users_id_equals_orders_user_id;
    }

let test_canonical_users_id_equals_orders_user_id_folds () =
  (* [users | join orders on users.id = orders.user_id]: users.id is the
     PK of [users], so users is the inner. Orders streams as outer; the
     outer's [orders.user_id] is the probe key. Users sat on the left of
     the CrossProduct, so inner_position = Left -- output columns are
     users.* then orders.* . *)
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog
      users_join_orders_on_pk_equality
  in
  Alcotest.(check physical_testable)
    "Restrict(CrossProduct, users.id = orders.user_id) -> \
     IndexedNestedLoopJoin streaming orders, probing users"
    (Physical.IndexedNestedLoopJoin
       {
         outer = Physical.FullScan { table = "orders" };
         inner_table = "users";
         outer_key_column = orders_user_id_column;
         inner_position = `Left;
       })
    physical

let test_mirrored_equality_folds_to_the_same_indexed_join () =
  (* [orders.user_id = users.id] is the same equality with sides
     swapped; the rewrite must recognise both orientations. *)
  let predicate =
    expression_compare ~left:(Column orders_user_id_column) ~op:Equal
      ~right:(Column users_id_column)
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "mirrored PK equality produces the same indexed join"
    (Physical.IndexedNestedLoopJoin
       {
         outer = Physical.FullScan { table = "orders" };
         inner_table = "users";
         outer_key_column = orders_user_id_column;
         inner_position = `Left;
       })
    physical

let test_syntactic_flip_picks_users_as_inner_with_right_position () =
  (* CrossProduct now has orders on the left and users on the right.
     Users is still the only PK-equality candidate, so users is still
     the inner -- but now its logical side is Right, so the output's
     column order is orders.* then users.* (outer-then-inner). *)
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "orders" };
              right = Scan { table = "users" };
            };
        predicate = users_id_equals_orders_user_id;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "users on the right -> inner_position = Right"
    (Physical.IndexedNestedLoopJoin
       {
         outer = Physical.FullScan { table = "orders" };
         inner_table = "users";
         outer_key_column = orders_user_id_column;
         inner_position = `Right;
       })
    physical

let test_both_sides_qualify_tiebreaker_picks_right_as_inner () =
  (* [users.id = admins.id] over [Scan users x Scan admins]: both
     tables have an Int64 PK named [id], and each side of the equality
     references one candidate's PK. The plan's tiebreaker says prefer
     left as outer, right as inner -- so admins (right) becomes the
     inner with inner_position = Right. *)
  let predicate =
    expression_compare ~left:(Column users_id_column) ~op:Equal
      ~right:(Column admins_id_column)
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "admins" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_admins_catalog logical
  in
  Alcotest.(check physical_testable)
    "both qualify -> right (admins) is the inner"
    (Physical.IndexedNestedLoopJoin
       {
         outer = Physical.FullScan { table = "users" };
         inner_table = "admins";
         outer_key_column = users_id_column;
         inner_position = `Right;
       })
    physical

let test_inner_candidate_wrapped_in_project_falls_back () =
  (* The rewrite only recognises bare [Scan]s as inner candidates,
     because the inner has to bottom out at "open this table's storage
     map". If a side is wrapped in [Project] (or any other operator),
     translation should fall through to a plain NestedLoopJoin. *)
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left =
                Project
                  {
                    input = Scan { table = "users" };
                    columns = [ row_column_reference "id" ];
                  };
              right = Scan { table = "orders" };
            };
        predicate = users_id_equals_orders_user_id;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "users wrapped in Project -> NestedLoopJoin fallback"
    (Physical.NestedLoopJoin
       {
         left =
           Physical.Project
             {
               input = Physical.FullScan { table = "users" };
               columns = [ row_column_reference "id" ];
             };
         right = Physical.FullScan { table = "orders" };
         predicate = users_id_equals_orders_user_id;
       })
    physical

let test_equality_on_non_pk_columns_falls_back () =
  (* [users.name = orders.description]: neither column is a PK, so the
     indexed rewrite doesn't apply. Falls through to NestedLoopJoin. *)
  let predicate =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"users" ~name:"name")
      ~op:Equal
      ~right:
        (expression_qualified_column ~qualifier:"orders" ~name:"description")
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "non-PK equality -> NestedLoopJoin fallback"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate;
       })
    physical

let test_ordering_predicate_falls_back () =
  (* [users.id < orders.user_id]: the column references would qualify,
     but the operator isn't Equal. Falls through. *)
  let predicate =
    expression_compare ~left:(Column users_id_column) ~op:Less
      ~right:(Column orders_user_id_column)
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "non-Equal predicate -> NestedLoopJoin fallback"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate;
       })
    physical

let test_both_sides_reference_the_same_scan_falls_back () =
  (* [users.id = users.id] over [Scan users x Scan users]: the
     "exactly one of a/b is the inner's PK" check fails because both
     sides match the same candidate. Neither candidate qualifies; the
     translation falls back to NestedLoopJoin. *)
  let predicate =
    expression_compare ~left:(Column users_id_column) ~op:Equal
      ~right:(Column users_id_column)
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "users" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "self-join self-equality -> NestedLoopJoin fallback"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "users" };
         predicate;
       })
    physical

let test_multiple_pk_eqs_pick_the_first_conjunct () =
  (* Two PK-equalities, each matching a *different* candidate:
     conjunct 0 (users.id = admins.level) matches the users candidate
     only; conjunct 1 (users.active = admins.id) matches the admins
     candidate only. The "first in conjunct order wins" rule means
     users is folded as inner; conjunct 1 stays in the residual. *)
  let users_id_equals_admins_level =
    expression_compare ~left:(Column users_id_column) ~op:Equal
      ~right:(expression_qualified_column ~qualifier:"admins" ~name:"level")
  in
  let users_active_equals_admins_id =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"users" ~name:"active")
      ~op:Equal ~right:(Column admins_id_column)
  in
  let predicate =
    expression_and ~left:users_id_equals_admins_level
      ~right:users_active_equals_admins_id
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "admins" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_admins_catalog logical
  in
  Alcotest.(check physical_testable)
    "first PK-eq conjunct wins; later PK-eq goes to residual"
    (Physical.Filter
       {
         input =
           Physical.IndexedNestedLoopJoin
             {
               outer = Physical.FullScan { table = "admins" };
               inner_table = "users";
               outer_key_column =
                 qualified_row_column_reference ~qualifier:"admins"
                   ~name:"level";
               inner_position = `Left;
             };
         predicate = users_active_equals_admins_id;
       })
    physical

let test_nested_and_tree_flattens_before_partitioning () =
  (* [(users.id = orders.user_id and r1) and r2]: a left-nested [And]
     tree. The partitioning step flattens it into [pk_eq; r1; r2] and
     folds the PK-eq, leaving [r1 and r2] in the residual. The residual
     conjuncts rebuild left-associatively, mirroring the parser's
     and-chains. *)
  let r1 = expression_column "active" in
  let r2 =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"orders" ~name:"amount")
      ~op:Greater
      ~right:(expression_literal (Scalar.Int64 5L))
  in
  let predicate =
    expression_and
      ~left:(expression_and ~left:users_id_equals_orders_user_id ~right:r1)
      ~right:r2
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "nested And tree flattens; residual rebuilt left-associatively"
    (Physical.Filter
       {
         input =
           Physical.IndexedNestedLoopJoin
             {
               outer = Physical.FullScan { table = "orders" };
               inner_table = "users";
               outer_key_column = orders_user_id_column;
               inner_position = `Left;
             };
         predicate = expression_and ~left:r1 ~right:r2;
       })
    physical

let test_reversed_conjunct_order_folds_to_the_same_plan () =
  (* [orders.amount > 5 and users.id = orders.user_id]: same conjuncts
     as the canonical residual case, but with the PK-eq conjunct in the
     trailing position. The partition walk finds the PK-eq wherever it
     sits, so the resulting plan is identical to the leading-PK-eq
     version (residual conjuncts otherwise preserve order). *)
  let residual = expression_column "active" in
  let predicate =
    expression_and ~left:residual ~right:users_id_equals_orders_user_id
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "reversed conjunct order folds to the same Filter(residual, INLJ)"
    (Physical.Filter
       {
         input =
           Physical.IndexedNestedLoopJoin
             {
               outer = Physical.FullScan { table = "orders" };
               inner_table = "users";
               outer_key_column = orders_user_id_column;
               inner_position = `Left;
             };
         predicate = residual;
       })
    physical

let test_pk_equality_with_residual_conjunct_folds_and_wraps_in_filter () =
  (* [users.id = orders.user_id and active]: the PK-equality conjunct
     folds into the IndexedNestedLoopJoin; the [active] conjunct stays
     in a wrapping Filter. (The bare [active] reference is resolved
     against the join's combined schema at eval time, the same way the
     pre-fold NestedLoopJoin would have resolved it.) *)
  let residual = expression_column "active" in
  let predicate =
    expression_and ~left:users_id_equals_orders_user_id ~right:residual
  in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "PK-eq + residual -> Filter(residual, IndexedNestedLoopJoin(...))"
    (Physical.Filter
       {
         input =
           Physical.IndexedNestedLoopJoin
             {
               outer = Physical.FullScan { table = "orders" };
               inner_table = "users";
               outer_key_column = orders_user_id_column;
               inner_position = `Left;
             };
         predicate = residual;
       })
    physical

let test_on_clause_and_trailing_restrict_produce_the_same_plan () =
  (* Syntactic-equivalence invariant: a conjunct lives in the same
     physical plan whether the user spells it on the [on]-clause or in
     a trailing [| restrict]. Building both as logical plans:

       (a) Restrict(CrossProduct, pk_eq and amount_gt)
       (b) Restrict(Restrict(CrossProduct, pk_eq), amount_gt)

     ... and translating both should produce equal Physical.t values.
     Without partitioning (or with a pushdown rule that ran on (a)
     only), the two forms would diverge -- the user's stylistic choice
     would silently change performance. *)
  let amount_greater_than_five =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"orders" ~name:"amount")
      ~op:Greater
      ~right:(expression_literal (Scalar.Int64 5L))
  in
  let cross_product : Logical.t =
    CrossProduct
      { left = Scan { table = "users" }; right = Scan { table = "orders" } }
  in
  let on_clause_form : Logical.t =
    Restrict
      {
        input = cross_product;
        predicate =
          expression_and ~left:users_id_equals_orders_user_id
            ~right:amount_greater_than_five;
      }
  in
  let trailing_restrict_form : Logical.t =
    Restrict
      {
        input =
          Restrict
            {
              input = cross_product;
              predicate = users_id_equals_orders_user_id;
            };
        predicate = amount_greater_than_five;
      }
  in
  let from_on_clause =
    Translate.translate ~catalog:users_and_orders_catalog on_clause_form
  in
  let from_trailing_restrict =
    Translate.translate ~catalog:users_and_orders_catalog trailing_restrict_form
  in
  Alcotest.(check physical_testable)
    "on-clause [and] and trailing [| restrict] yield the same plan"
    from_on_clause from_trailing_restrict

let test_conjunction_with_no_pk_equality_falls_back () =
  (* [users.name = orders.description and orders.amount > 5]: every
     conjunct involves non-PK columns, so no candidate's PK is named
     by any conjunct. Falls back to NestedLoopJoin carrying the full
     predicate (not partitioned). *)
  let conjunct_a =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"users" ~name:"name")
      ~op:Equal
      ~right:
        (expression_qualified_column ~qualifier:"orders" ~name:"description")
  in
  let conjunct_b =
    expression_compare
      ~left:(expression_qualified_column ~qualifier:"orders" ~name:"amount")
      ~op:Greater
      ~right:(expression_literal (Scalar.Int64 5L))
  in
  let predicate = expression_and ~left:conjunct_a ~right:conjunct_b in
  let logical : Logical.t =
    Restrict
      {
        input =
          CrossProduct
            {
              left = Scan { table = "users" };
              right = Scan { table = "orders" };
            };
        predicate;
      }
  in
  let physical =
    Translate.translate ~catalog:users_and_orders_catalog logical
  in
  Alcotest.(check physical_testable)
    "conjunction with no PK-eq -> NestedLoopJoin with the full predicate"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate;
       })
    physical

let test_inner_table_catalog_miss_falls_back () =
  (* If the catalog doesn't know about either base table, no
     candidate qualifies. Mirrors [IndexLookup]'s catalog-miss
     behaviour. *)
  let physical =
    Translate.translate ~catalog:noop_catalog users_join_orders_on_pk_equality
  in
  Alcotest.(check physical_testable)
    "catalog returns None -> NestedLoopJoin fallback"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate = users_id_equals_orders_user_id;
       })
    physical

let () =
  Alcotest.run "translate_indexed_nested_loop_join"
    [
      ( "fold",
        [
          Alcotest.test_case
            "users.id = orders.user_id folds: users as inner, Left position"
            `Quick test_canonical_users_id_equals_orders_user_id_folds;
          Alcotest.test_case
            "mirrored equality (orders.user_id = users.id) folds to the same \
             plan"
            `Quick test_mirrored_equality_folds_to_the_same_indexed_join;
          Alcotest.test_case
            "syntactic flip (orders on left, users on right) yields \
             inner_position = Right"
            `Quick test_syntactic_flip_picks_users_as_inner_with_right_position;
          Alcotest.test_case
            "both sides qualify -> tiebreaker picks right as inner" `Quick
            test_both_sides_qualify_tiebreaker_picks_right_as_inner;
          Alcotest.test_case
            "PK-eq + residual conjunct folds into Filter(residual, \
             IndexedNestedLoopJoin)"
            `Quick
            test_pk_equality_with_residual_conjunct_folds_and_wraps_in_filter;
          Alcotest.test_case
            "reversed conjunct order (residual first) folds to the same plan"
            `Quick test_reversed_conjunct_order_folds_to_the_same_plan;
          Alcotest.test_case "nested And tree flattens before partitioning"
            `Quick test_nested_and_tree_flattens_before_partitioning;
          Alcotest.test_case
            "multiple PK-eqs across different candidates: first conjunct wins"
            `Quick test_multiple_pk_eqs_pick_the_first_conjunct;
          Alcotest.test_case
            "on-clause [and] and trailing [| restrict] produce the same plan"
            `Quick test_on_clause_and_trailing_restrict_produce_the_same_plan;
        ] );
      ( "no fold",
        [
          Alcotest.test_case
            "non-bare-Scan side (Project wrapping a scan) falls back" `Quick
            test_inner_candidate_wrapped_in_project_falls_back;
          Alcotest.test_case "equality on non-PK columns falls back" `Quick
            test_equality_on_non_pk_columns_falls_back;
          Alcotest.test_case "ordering predicate (id < user_id) falls back"
            `Quick test_ordering_predicate_falls_back;
          Alcotest.test_case
            "both sides of the equality reference the same scan falls back"
            `Quick test_both_sides_reference_the_same_scan_falls_back;
          Alcotest.test_case
            "conjunction with no PK-equality conjunct falls back" `Quick
            test_conjunction_with_no_pk_equality_falls_back;
          Alcotest.test_case "inner table catalog miss falls back" `Quick
            test_inner_table_catalog_miss_falls_back;
        ] );
    ]
