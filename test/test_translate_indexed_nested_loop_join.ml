(** Tests for [Translate]'s [IndexedNestedLoopJoin] rewrite.

    The rewrite widens the existing
    [Restrict (CrossProduct (left, right), predicate)] arm: when one side is a
    bare [Scan] whose catalog schema has a single-column [Int64] primary key,
    and the predicate is a cross-side equality naming that PK column on exactly
    one side, translate emits an [IndexedNestedLoopJoin] streaming the other
    side. Every other shape (no matching PK, non-bare scans, non-equality
    predicates, conjunctions) falls through to today's
    {!Physical.NestedLoopJoin}.

    Step 2's recogniser is deliberately narrow: only the bare
    [Compare (Column, Equal, Column)] shape is matched. Conjunct flattening
    arrives in step 3.

    Each test builds its own in-test catalog so the unit tests don't need a live
    LMDB environment; pipeline-level integration tests live in
    [test_pipeline.ml]. *)

open Dovetail
open Test_helpers

(* A users schema with a single int64 primary key, identical to
   [Fixture.users_schema] but rebuilt in-test so unit tests don't need
   the LMDB fixture. *)
let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "users" };
        { name = "name"; kind = String; qualifier = Some "users" };
        { name = "email"; kind = String; qualifier = Some "users" };
        { name = "active"; kind = Bool; qualifier = Some "users" };
      ];
    primary_key = [ "id" ];
  }

(* An orders schema with a single int64 primary key. Same shape as the
   fixture's, but locally defined for unit-test independence. *)
let orders_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "orders" };
        { name = "user_id"; kind = Int64; qualifier = Some "orders" };
        { name = "description"; kind = String; qualifier = Some "orders" };
        { name = "amount"; kind = Int64; qualifier = Some "orders" };
      ];
    primary_key = [ "id" ];
  }

(* A second table whose primary key is also a single Int64 [id]. Used to
   build the "both sides qualify" tiebreaker case: [users.id = admins.id]
   has the PK column referenced on both sides of the equality. *)
let admins_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64; qualifier = Some "admins" };
        { name = "level"; kind = Int64; qualifier = Some "admins" };
      ];
    primary_key = [ "id" ];
  }

(* A catalog that knows about [users] and [orders]. The canonical test
   case for the rewrite uses this. *)
let users_and_orders_catalog table_name =
  match table_name with
  | "users" -> Some users_schema
  | "orders" -> Some orders_schema
  | _ -> None

(* A catalog that knows about [users] and [admins] -- both with PK [id]
   in the same kind. Drives the both-sides-qualify tiebreaker test. *)
let users_and_admins_catalog table_name =
  match table_name with
  | "users" -> Some users_schema
  | "admins" -> Some admins_schema
  | _ -> None

let users_id_column = qualified_column_reference ~qualifier:"users" ~name:"id"

let orders_user_id_column =
  qualified_column_reference ~qualifier:"orders" ~name:"user_id"

let admins_id_column = qualified_column_reference ~qualifier:"admins" ~name:"id"

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
                    columns = [ column_reference "id" ];
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
               columns = [ column_reference "id" ];
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

let test_conjunction_predicate_falls_back_in_step_2 () =
  (* Step 2 only recognises a bare [Compare]. Any [And] at the top
     level (or nested) falls through; step 3 will partition the
     conjunct list and absorb a PK-eq into the indexed join. *)
  let predicate =
    expression_and ~left:users_id_equals_orders_user_id
      ~right:(expression_column "active")
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
    "predicate with And -> NestedLoopJoin fallback (step 3 handles this)"
    (Physical.NestedLoopJoin
       {
         left = Physical.FullScan { table = "users" };
         right = Physical.FullScan { table = "orders" };
         predicate;
       })
    physical

let test_inner_table_catalog_miss_falls_back () =
  (* If the catalog doesn't know about either base table, no
     candidate qualifies. Mirrors slice 8's catalog-miss behaviour. *)
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
            "predicate with And falls back in step 2 (step 3 closes this)"
            `Quick test_conjunction_predicate_falls_back_in_step_2;
          Alcotest.test_case "inner table catalog miss falls back" `Quick
            test_inner_table_catalog_miss_falls_back;
        ] );
    ]
