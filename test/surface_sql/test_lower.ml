(** Tests for [Lower]. *)

open Dovetail_surface_sql
module Plan = Dovetail_plan

let logical_testable : Plan.Logical.t Alcotest.testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical-plan>")) ( = )

let test_select_star_lowers_to_scan () =
  let ast = Ast.Select { select_list = Ast.All; from = "users" } in
  let logical = Lower.lower ast in
  Alcotest.(check logical_testable)
    "SELECT * FROM users -> Scan(users)"
    (Scan { table = "users" })
    logical

let () =
  Alcotest.run "sql_lower"
    [
      ( "select star",
        [
          Alcotest.test_case "SELECT * lowers to a bare Scan (no Project)"
            `Quick test_select_star_lowers_to_scan;
        ] );
    ]
