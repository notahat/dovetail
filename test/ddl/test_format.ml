(** Tests for [Dovetail_ddl.Format].

    Today's only DDL statement [:list tables] renders as a fixed one-liner. *)

module Ddl = Dovetail_ddl

let test_format_list_tables () =
  Alcotest.(check string)
    "List_tables renders as :list tables" ":list tables"
    (Ddl.Format.statement Ddl.Statement.List_tables)

let () =
  Alcotest.run "format"
    [
      ( "one-liners",
        [ Alcotest.test_case "List_tables" `Quick test_format_list_tables ] );
    ]
