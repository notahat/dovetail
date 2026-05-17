(** Tests for [Cli.parse]: argv parsing into options or a structured error. *)

open Dovetail

let options_testable =
  Alcotest.testable
    (Fmt.of_to_string (fun (options : Cli.options) ->
         Printf.sprintf "{ show_physical = %b; environment_path = %S }"
           options.show_physical options.environment_path))
    ( = )

let check_parse_ok ~label expected arguments =
  match Cli.parse arguments with
  | Ok options -> Alcotest.check options_testable label expected options
  | Error message ->
      Alcotest.failf "%s: expected Ok, got Error %S" label message

let check_parse_error ~label expected_message arguments =
  match Cli.parse arguments with
  | Ok _ -> Alcotest.failf "%s: expected Error, got Ok" label
  | Error message -> Alcotest.(check string) label expected_message message

let test_empty_arguments_yield_defaults () =
  check_parse_ok ~label:"defaults"
    { show_physical = false; environment_path = Cli.default_environment_path }
    []

let test_flag_alone_sets_show_physical_and_leaves_path_default () =
  check_parse_ok ~label:"flag only"
    { show_physical = true; environment_path = Cli.default_environment_path }
    [ "--show-physical" ]

let test_path_alone_sets_environment_path () =
  check_parse_ok ~label:"path only"
    { show_physical = false; environment_path = "/tmp/example" }
    [ "/tmp/example" ]

let test_flag_then_path_sets_both () =
  check_parse_ok ~label:"flag then path"
    { show_physical = true; environment_path = "/tmp/example" }
    [ "--show-physical"; "/tmp/example" ]

let test_path_then_flag_sets_both () =
  check_parse_ok ~label:"path then flag"
    { show_physical = true; environment_path = "/tmp/example" }
    [ "/tmp/example"; "--show-physical" ]

let test_duplicate_flag_is_rejected () =
  check_parse_error ~label:"duplicate flag" "duplicate --show-physical flag"
    [ "--show-physical"; "--show-physical" ]

let test_multiple_paths_are_rejected () =
  check_parse_error ~label:"two paths" "multiple environment paths"
    [ "/tmp/one"; "/tmp/two" ]

let () =
  Alcotest.run "cli"
    [
      ( "parse",
        [
          Alcotest.test_case "no arguments yields the defaults" `Quick
            test_empty_arguments_yield_defaults;
          Alcotest.test_case "--show-physical alone sets the flag" `Quick
            test_flag_alone_sets_show_physical_and_leaves_path_default;
          Alcotest.test_case "a single non-flag argument sets the path" `Quick
            test_path_alone_sets_environment_path;
          Alcotest.test_case "--show-physical before a path sets both" `Quick
            test_flag_then_path_sets_both;
          Alcotest.test_case "--show-physical after a path sets both" `Quick
            test_path_then_flag_sets_both;
          Alcotest.test_case "a repeated --show-physical is rejected" `Quick
            test_duplicate_flag_is_rejected;
          Alcotest.test_case "two non-flag arguments are rejected" `Quick
            test_multiple_paths_are_rejected;
        ] );
    ]
