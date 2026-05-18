(** Tests for [Statement].

    Covers the slice-12 vocabulary: [classify] for both statement constructors.
    The constructor surface ([List_tables], [Drop_table]) is exercised through
    the parser ({!Test_parser}) and the executor ({!Test_ddl_executor}); this
    file pins only the read/write routing decision that drives transaction
    selection in the REPL. *)

open Dovetail

let test_list_tables_classifies_as_read () =
  Alcotest.(check bool)
    "List_tables classifies as Read" true
    (Statement.classify Statement.List_tables = `Read)

let test_drop_table_classifies_as_write () =
  Alcotest.(check bool)
    "Drop_table classifies as Write" true
    (Statement.classify (Statement.Drop_table { table_name = "users" }) = `Write)

let () =
  Alcotest.run "statement"
    [
      ( "classify",
        [
          Alcotest.test_case "List_tables classifies as Read" `Quick
            test_list_tables_classifies_as_read;
          Alcotest.test_case "Drop_table classifies as Write" `Quick
            test_drop_table_classifies_as_write;
        ] );
    ]
