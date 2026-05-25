(** Tests for [Typecheck].

    The pass is a no-op bootstrap at this point: it accepts any [Logical.t],
    returns it unchanged, and reports no errors. Tests grow as error
    constructors are added. *)

open Dovetail_plan
module Catalog = Dovetail_core.Catalog

let logical_testable =
  Alcotest.testable (Fmt.of_to_string (fun _ -> "<logical>")) ( = )

let test_empty_pass_returns_input_unchanged () =
  let catalog : Catalog.kind = { relation_kinds = [] } in
  let plan : Logical.t = Scan { table = "users" } in
  match Typecheck.typecheck ~catalog plan with
  | Ok result -> Alcotest.(check logical_testable) "plan unchanged" plan result
  | Error _ -> Alcotest.fail "expected Ok with no errors"

let () =
  Alcotest.run "typecheck"
    [
      ( "no-op pass",
        [
          Alcotest.test_case "returns input unchanged" `Quick
            test_empty_pass_returns_input_unchanged;
        ] );
    ]
