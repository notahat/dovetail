(* Entry point: parse argv via [Dovetail.Cli], open the environment,
   populate the fixture if needed, and hand off to the REPL. The bulk of
   the work lives in [Dovetail.*] so it's testable without spawning a
   subprocess. *)

let usage program_name =
  Printf.sprintf "usage: %s [%s] [environment-path]" program_name
    Dovetail.Cli.show_physical_flag

let parse_argv_or_exit argv =
  let arguments = Array.to_list argv |> List.tl in
  match Dovetail.Cli.parse arguments with
  | Ok options -> options
  | Error message ->
      Printf.eprintf "%s\n%s\n" message (usage argv.(0));
      exit 2

(* Adapt [stdin] to [Repl.run]'s [read_line] callback: return [None] on
   EOF rather than raising. *)
let read_line_from_stdin () =
  match input_line stdin with
  | line -> Some line
  | exception End_of_file -> None

let () =
  let { Dovetail.Cli.show_physical; environment_path } =
    parse_argv_or_exit Sys.argv
  in
  let environment = Dovetail.Storage.open_environment environment_path in
  Fun.protect
    ~finally:(fun () -> Dovetail.Storage.close_environment environment)
    (fun () ->
      Dovetail.Fixture.populate_if_empty environment;
      Dovetail.Repl.run ~show_physical environment
        ~read_line:read_line_from_stdin ~output:Format.std_formatter)
