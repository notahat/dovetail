(* Slice-1 entry point: parse argv, open the environment, populate the
   fixture if needed, and hand off to the REPL. The bulk of the work lives
   in [Dovetail.Repl] so the loop logic is testable without spawning a
   subprocess. *)

let default_environment_path = "./dovetail-data"
let show_physical_flag = "--show-physical"

let usage program_name =
  Printf.sprintf "usage: %s [%s] [environment-path]" program_name
    show_physical_flag

(* Hand-rolled argv split: [--show-physical] is a boolean flag that may
   appear in any position; everything else is taken as the optional
   environment path. Two paths or two flags both fail with the usage
   message. The codebase doesn't take a CLI library dependency yet, and
   one flag isn't enough motivation to add one. *)
type cli_options = { show_physical : bool; environment_path : string }

let parse_cli argv =
  let positional_arguments = ref [] in
  let show_physical = ref false in
  Array.iteri
    (fun index argument ->
      if index = 0 then ()
      else if argument = show_physical_flag then
        if !show_physical then (
          Printf.eprintf "%s\n" (usage argv.(0));
          exit 2)
        else show_physical := true
      else positional_arguments := argument :: !positional_arguments)
    argv;
  let environment_path =
    match List.rev !positional_arguments with
    | [] -> default_environment_path
    | [ path ] -> path
    | _ ->
        Printf.eprintf "%s\n" (usage argv.(0));
        exit 2
  in
  { show_physical = !show_physical; environment_path }

(* Adapt [stdin] to [Repl.run]'s [read_line] callback: return [None] on
   EOF rather than raising. *)
let read_line_from_stdin () =
  match input_line stdin with
  | line -> Some line
  | exception End_of_file -> None

let () =
  let { show_physical; environment_path } = parse_cli Sys.argv in
  let environment = Dovetail.Storage.open_environment environment_path in
  Fun.protect
    ~finally:(fun () -> Dovetail.Storage.close_environment environment)
    (fun () ->
      Dovetail.Fixture.populate_if_empty environment;
      Dovetail.Repl.run ~show_physical environment
        ~read_line:read_line_from_stdin ~output:Format.std_formatter)
