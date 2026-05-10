(** Tests for [Relation]. *)

open Dovetail

let users_schema : Schema.t =
  {
    fields =
      [
        { name = "id"; kind = Int64 };
        { name = "name"; kind = String };
        { name = "email"; kind = String };
        { name = "active"; kind = Bool };
      ];
    primary_key = [ "id" ];
  }

let two_users : Schema.tuple list =
  [
    [|
      Value.Int64 1L;
      Value.String "Alice";
      Value.String "alice@example.com";
      Value.Bool true;
    |];
    [|
      Value.Int64 10L;
      Value.String "Bob";
      Value.String "bob@example.com";
      Value.Bool false;
    |];
  ]

let render relation =
  let buffer = Buffer.create 256 in
  let formatter = Format.formatter_of_buffer buffer in
  Relation.print ~formatter relation;
  Format.pp_print_flush formatter ();
  Buffer.contents buffer

let test_renders_aligned_table () =
  let relation : [ `Bag ] Relation.t =
    { schema = users_schema; tuples = List.to_seq two_users }
  in
  let expected =
    String.concat "\n"
      [
        "| id | name  | email             | active |";
        "|----|-------|-------------------|--------|";
        "|  1 | Alice | alice@example.com | true   |";
        "| 10 | Bob   | bob@example.com   | false  |";
        "";
      ]
  in
  Alcotest.(check string) "rendered table" expected (render relation)

let test_renders_header_only_when_empty () =
  let relation : [ `Bag ] Relation.t =
    { schema = users_schema; tuples = Seq.empty }
  in
  let expected =
    String.concat "\n"
      [ "| id | name | email | active |"; "|----|------|-------|--------|"; "" ]
  in
  Alcotest.(check string) "header-only table" expected (render relation)

let () =
  Alcotest.run "relation"
    [
      ( "print",
        [
          Alcotest.test_case "renders an aligned table for a populated relation"
            `Quick test_renders_aligned_table;
          Alcotest.test_case
            "renders just the header when the relation has no tuples" `Quick
            test_renders_header_only_when_empty;
        ] );
    ]
