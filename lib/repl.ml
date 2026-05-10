let prompt = "> "

(* Run a single parsed query against [environment] and pretty-print the
   result to [output]. Evaluation failures are caught and reported as a
   one-line error so the surrounding loop can keep going. *)
let evaluate_and_print environment ~output logical =
  let physical = Translate.translate logical in
  Storage.with_read_transaction environment (fun transaction ->
      match Eval.eval environment transaction physical with
      | relation -> Relation.print ~formatter:output relation
      | exception Failure message -> Format.fprintf output "error: %s@." message)

(* Process one input line: parse, lower, evaluate, print. Parse and eval
   errors land in [output]; nothing is raised. *)
let process_line environment ~output line =
  match Parser.parse line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok ast ->
      let logical = Lower.lower ast in
      evaluate_and_print environment ~output logical

let run environment ~read_line ~output =
  let rec loop () =
    Format.fprintf output "%s" prompt;
    Format.pp_print_flush output ();
    match read_line () with
    | None -> ()
    | Some line ->
        if String.length (String.trim line) > 0 then
          process_line environment ~output line;
        loop ()
  in
  loop ()
