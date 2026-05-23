(** Tests for [Dovetail_ddl.Format].

    Pins the canonical-form printer for every [Statement.t] constructor: the two
    one-liner shapes ([:list tables], [:drop table <name>]) and the multi-line
    [:create table ...] form. The [users] and [order_items] examples are taken
    verbatim from [docs/plans/ddl-design.md] so the canonical form stays
    anchored to the design document; future changes to the printer have to touch
    this file and the doc together. *)

module Ddl = Dovetail_ddl
module Scalar = Dovetail_core.Scalar

let test_format_list_tables () =
  Alcotest.(check string)
    "List_tables renders as :list tables" ":list tables"
    (Ddl.Format.statement Ddl.Statement.List_tables)

let test_format_drop_table () =
  Alcotest.(check string)
    "Drop_table renders as :drop table <name>" ":drop table widgets"
    (Ddl.Format.statement (Ddl.Statement.Drop_table { table_name = "widgets" }))

(* Build a [Create_table] statement for the canonical-form tests below. *)
let make_create_table ~table_name ~fields ~primary_key : Ddl.Statement.t =
  Create_table { table_name; fields; primary_key }

let test_format_create_table_int64 () =
  let statement =
    make_create_table ~table_name:"widgets"
      ~fields:[ { name = "id"; kind = Scalar.Int64 } ]
      ~primary_key:[ "id" ]
  in
  Alcotest.(check string)
    "single Int64 column renders canonically"
    ":create table widgets (\n  id: Int64,\n) primary key (id)"
    (Ddl.Format.statement statement)

let test_format_create_table_string () =
  let statement =
    make_create_table ~table_name:"widgets"
      ~fields:[ { name = "name"; kind = Scalar.String } ]
      ~primary_key:[ "name" ]
  in
  Alcotest.(check string)
    "single String column renders canonically"
    ":create table widgets (\n  name: String,\n) primary key (name)"
    (Ddl.Format.statement statement)

let test_format_create_table_bool () =
  let statement =
    make_create_table ~table_name:"widgets"
      ~fields:[ { name = "active"; kind = Scalar.Bool } ]
      ~primary_key:[ "active" ]
  in
  Alcotest.(check string)
    "single Bool column renders canonically"
    ":create table widgets (\n  active: Bool,\n) primary key (active)"
    (Ddl.Format.statement statement)

let test_format_create_table_compound_primary_key () =
  let statement =
    make_create_table ~table_name:"pairs"
      ~fields:
        [
          { name = "left"; kind = Scalar.Int64 };
          { name = "right"; kind = Scalar.Int64 };
        ]
      ~primary_key:[ "left"; "right" ]
  in
  Alcotest.(check string)
    "compound primary key uses comma-space separator"
    ":create table pairs (\n\
    \  left: Int64,\n\
    \  right: Int64,\n\
     ) primary key (left, right)"
    (Ddl.Format.statement statement)

(* The [users] example from [docs/plans/ddl-design.md]. *)
let test_format_create_table_users_example () =
  let statement =
    make_create_table ~table_name:"users"
      ~fields:
        [
          { name = "id"; kind = Scalar.Int64 };
          { name = "name"; kind = Scalar.String };
          { name = "email"; kind = Scalar.String };
          { name = "active"; kind = Scalar.Bool };
        ]
      ~primary_key:[ "id" ]
  in
  Alcotest.(check string)
    "users example matches the design doc"
    ":create table users (\n\
    \  id: Int64,\n\
    \  name: String,\n\
    \  email: String,\n\
    \  active: Bool,\n\
     ) primary key (id)"
    (Ddl.Format.statement statement)

(* The [order_items] example from [docs/plans/ddl-design.md]: compound PK. *)
let test_format_create_table_order_items_example () =
  let statement =
    make_create_table ~table_name:"order_items"
      ~fields:
        [
          { name = "order_id"; kind = Scalar.Int64 };
          { name = "product_id"; kind = Scalar.Int64 };
          { name = "quantity"; kind = Scalar.Int64 };
        ]
      ~primary_key:[ "order_id"; "product_id" ]
  in
  Alcotest.(check string)
    "order_items example matches the design doc"
    ":create table order_items (\n\
    \  order_id: Int64,\n\
    \  product_id: Int64,\n\
    \  quantity: Int64,\n\
     ) primary key (order_id, product_id)"
    (Ddl.Format.statement statement)

let () =
  Alcotest.run "format"
    [
      ( "one-liners",
        [
          Alcotest.test_case "List_tables" `Quick test_format_list_tables;
          Alcotest.test_case "Drop_table" `Quick test_format_drop_table;
        ] );
      ( "create table",
        [
          Alcotest.test_case "single Int64 column" `Quick
            test_format_create_table_int64;
          Alcotest.test_case "single String column" `Quick
            test_format_create_table_string;
          Alcotest.test_case "single Bool column" `Quick
            test_format_create_table_bool;
          Alcotest.test_case "compound primary key" `Quick
            test_format_create_table_compound_primary_key;
        ] );
      ( "design doc examples",
        [
          Alcotest.test_case "users" `Quick
            test_format_create_table_users_example;
          Alcotest.test_case "order_items" `Quick
            test_format_create_table_order_items_example;
        ] );
    ]
