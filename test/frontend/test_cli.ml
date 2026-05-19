(** Tests for [Cli.parse]: argv parsing into options or a structured error. *)

open Dovetail_frontend

let options_testable =
  Alcotest.testable
    (Fmt.of_to_string (fun (options : Cli.options) ->
         Printf.sprintf
           "{ show_logical = %b; show_physical = %b; demo_data = %b; \
            environment_path = %S }"
           options.show_logical options.show_physical options.demo_data
           options.environment_path))
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
    {
      show_logical = false;
      show_physical = false;
      demo_data = false;
      environment_path = Cli.default_environment_path;
    }
    []

let test_flag_alone_sets_show_physical_and_leaves_path_default () =
  check_parse_ok ~label:"flag only"
    {
      show_logical = false;
      show_physical = true;
      demo_data = false;
      environment_path = Cli.default_environment_path;
    }
    [ "--show-physical" ]

let test_path_alone_sets_environment_path () =
  check_parse_ok ~label:"path only"
    {
      show_logical = false;
      show_physical = false;
      demo_data = false;
      environment_path = "/tmp/example";
    }
    [ "/tmp/example" ]

let test_flag_then_path_sets_both () =
  check_parse_ok ~label:"flag then path"
    {
      show_logical = false;
      show_physical = true;
      demo_data = false;
      environment_path = "/tmp/example";
    }
    [ "--show-physical"; "/tmp/example" ]

let test_path_then_flag_sets_both () =
  check_parse_ok ~label:"path then flag"
    {
      show_logical = false;
      show_physical = true;
      demo_data = false;
      environment_path = "/tmp/example";
    }
    [ "/tmp/example"; "--show-physical" ]

let test_duplicate_flag_is_rejected () =
  check_parse_error ~label:"duplicate flag" "duplicate --show-physical flag"
    [ "--show-physical"; "--show-physical" ]

let test_multiple_paths_are_rejected () =
  check_parse_error ~label:"two paths" "multiple environment paths"
    [ "/tmp/one"; "/tmp/two" ]

let test_demo_data_alone_sets_the_flag () =
  check_parse_ok ~label:"demo-data only"
    {
      show_logical = false;
      show_physical = false;
      demo_data = true;
      environment_path = Cli.default_environment_path;
    }
    [ "--demo-data" ]

let test_demo_data_combines_with_show_physical_and_path () =
  check_parse_ok ~label:"demo-data with show-physical and path"
    {
      show_logical = false;
      show_physical = true;
      demo_data = true;
      environment_path = "/tmp/example";
    }
    [ "--demo-data"; "--show-physical"; "/tmp/example" ]

let test_duplicate_demo_data_is_rejected () =
  check_parse_error ~label:"duplicate demo-data" "duplicate --demo-data flag"
    [ "--demo-data"; "--demo-data" ]

let test_show_logical_alone_sets_the_flag () =
  check_parse_ok ~label:"show-logical only"
    {
      show_logical = true;
      show_physical = false;
      demo_data = false;
      environment_path = Cli.default_environment_path;
    }
    [ "--show-logical" ]

let test_show_logical_combines_with_path () =
  check_parse_ok ~label:"show-logical with path"
    {
      show_logical = true;
      show_physical = false;
      demo_data = false;
      environment_path = "/tmp/example";
    }
    [ "--show-logical"; "/tmp/example" ]

let test_duplicate_show_logical_is_rejected () =
  check_parse_error ~label:"duplicate show-logical"
    "duplicate --show-logical flag"
    [ "--show-logical"; "--show-logical" ]

let test_show_logical_and_show_physical_compose () =
  check_parse_ok ~label:"both show-* flags with demo-data and path"
    {
      show_logical = true;
      show_physical = true;
      demo_data = true;
      environment_path = "/tmp/example";
    }
    [ "--show-logical"; "--show-physical"; "--demo-data"; "/tmp/example" ]

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
          Alcotest.test_case "--demo-data alone sets the flag" `Quick
            test_demo_data_alone_sets_the_flag;
          Alcotest.test_case
            "--demo-data composes with --show-physical and a path" `Quick
            test_demo_data_combines_with_show_physical_and_path;
          Alcotest.test_case "a repeated --demo-data is rejected" `Quick
            test_duplicate_demo_data_is_rejected;
          Alcotest.test_case "--show-logical alone sets the flag" `Quick
            test_show_logical_alone_sets_the_flag;
          Alcotest.test_case "--show-logical composes with a path" `Quick
            test_show_logical_combines_with_path;
          Alcotest.test_case "a repeated --show-logical is rejected" `Quick
            test_duplicate_show_logical_is_rejected;
          Alcotest.test_case
            "--show-logical composes with --show-physical, --demo-data, and a \
             path"
            `Quick test_show_logical_and_show_physical_compose;
        ] );
    ]
