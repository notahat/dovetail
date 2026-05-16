let prompt = "> "

(* Run a single parsed query against [environment] and pretty-print the
   result to [output]. When [show_physical] is true, the chosen physical
   plan is printed before evaluation -- intended as an EXPLAIN-style aid
   for understanding which operators are firing. Evaluation and printing
   failures are caught and reported as a one-line error so the surrounding
   loop can keep going. With the CPS executor, printing runs inside the
   evaluator's continuation -- and therefore inside any live cursor scopes
   -- so [try]/[with] necessarily catches errors from both evaluation and
   printing. *)
let evaluate_and_print environment ~output ~show_physical logical =
  try
    Storage.with_read_transaction environment (fun transaction ->
        let catalog table_name =
          Catalog.get environment transaction ~table_name
        in
        let physical = Translate.translate ~catalog logical in
        if show_physical then Physical.format output physical;
        Eval.eval environment transaction physical (fun relation ->
            Relation.print ~formatter:output relation))
  with Failure message -> Format.fprintf output "error: %s@." message

(* Process one input line: parse, lower, evaluate, print. Parse and eval
   errors land in [output]; nothing is raised. *)
let process_line environment ~output ~show_physical line =
  match Parser.parse line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok ast ->
      let logical = Lower.lower ast in
      evaluate_and_print environment ~output ~show_physical logical

let run ?(show_physical = false) environment ~read_line ~output =
  let rec loop () =
    Format.fprintf output "%s" prompt;
    Format.pp_print_flush output ();
    match read_line () with
    | None -> ()
    | Some line ->
        if String.length (String.trim line) > 0 then
          process_line environment ~output ~show_physical line;
        loop ()
  in
  loop ()
