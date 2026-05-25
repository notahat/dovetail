(** Tests for [Statement].

    With the write-side DDL forms retired, [Statement.t] is a single nullary
    constructor and there's nothing left to assert at the type level. The sanity
    check below pins that today's only constructor remains constructible from
    outside the library. *)

module Ddl = Dovetail_ddl

let test_list_tables_is_constructible () =
  Alcotest.(check bool)
    "List_tables is the sole constructor of Ddl.Statement.t" true
    (match Ddl.Statement.List_tables with Ddl.Statement.List_tables -> true)

let () =
  Alcotest.run "statement"
    [
      ( "constructors",
        [
          Alcotest.test_case "List_tables is constructible" `Quick
            test_list_tables_is_constructible;
        ] );
    ]
