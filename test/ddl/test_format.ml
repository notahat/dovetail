(** Tests for [Dovetail_ddl.Format].

    Pins the canonical-form printer for every [Statement.t] constructor: the two
    one-liner shapes [:list tables] and [:drop table <name>]. *)

module Ddl = Dovetail_ddl

let test_format_list_tables () =
  Alcotest.(check string)
    "List_tables renders as :list tables" ":list tables"
    (Ddl.Format.statement Ddl.Statement.List_tables)

let test_format_drop_table () =
  Alcotest.(check string)
    "Drop_table renders as :drop table <name>" ":drop table widgets"
    (Ddl.Format.statement (Ddl.Statement.Drop_table { table_name = "widgets" }))

let () =
  Alcotest.run "format"
    [
      ( "one-liners",
        [
          Alcotest.test_case "List_tables" `Quick test_format_list_tables;
          Alcotest.test_case "Drop_table" `Quick test_format_drop_table;
        ] );
    ]
