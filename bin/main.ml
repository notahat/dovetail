(* Slice-1 entry point: parse argv, open the environment, populate the
   fixture if needed, and hand off to the REPL. The bulk of the work lives
   in [Dovetail.Repl] so the loop logic is testable without spawning a
   subprocess. *)

let default_environment_path = "./dovetail-data"

let parse_environment_path argv =
  match argv with
  | [| _ |] -> default_environment_path
  | [| _; path |] -> path
  | _ ->
      Printf.eprintf "usage: %s [environment-path]\n" argv.(0);
      exit 2

(* Adapt [stdin] to [Repl.run]'s [read_line] callback: return [None] on
   EOF rather than raising. *)
let read_line_from_stdin () =
  match input_line stdin with
  | line -> Some line
  | exception End_of_file -> None

let () =
  let environment_path = parse_environment_path Sys.argv in
  let environment = Dovetail.Storage.open_environment environment_path in
  Fun.protect
    ~finally:(fun () -> Dovetail.Storage.close_environment environment)
    (fun () ->
      Dovetail.Fixture.populate_if_empty environment;
      Dovetail.Repl.run environment ~read_line:read_line_from_stdin
        ~output:Format.std_formatter)
