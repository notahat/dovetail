(** Tests for [Logical.classify].

    [classify] reads the wrapper constructor off a [Logical.plan] and returns
    the transaction permission the REPL should open. The function has two arms
    and no inner inspection; the tests exercise both arms with minimal plans. *)

open Dovetail_plan
module Value = Dovetail_core.Value

let test_query_plan_classifies_as_read () =
  let plan : Logical.plan = Query (Scan { table = "users" }) in
  Alcotest.(check bool)
    "Query plan classifies as Read" true
    (Logical.classify plan = `Read)

let test_mutation_plan_classifies_as_write () =
  let plan : Logical.plan =
    Mutation
      (Insert
         {
           table = "orders";
           source =
             RelationLiteral
               { columns = [ "id" ]; rows = [ [ Value.Int64 7L ] ] };
         })
  in
  Alcotest.(check bool)
    "Mutation plan classifies as Write" true
    (Logical.classify plan = `Write)

let () =
  Alcotest.run "logical"
    [
      ( "classify",
        [
          Alcotest.test_case "Query plan classifies as Read" `Quick
            test_query_plan_classifies_as_read;
          Alcotest.test_case "Mutation plan classifies as Write" `Quick
            test_mutation_plan_classifies_as_write;
        ] );
    ]
