let prompt = "> "

(* Render the affected-row status line for a completed mutation. The verb is
   keyed off the [mutation] constructor so the classifier and the rendered
   word come from the same source of truth: a future [Update]/[Delete] adds
   one constructor and one verb here and the rest of the renderer reuses. *)
let format_mutation_status mutation affected_rows =
  let verb = match mutation with Physical.Insert _ -> "inserted" in
  let noun = if affected_rows = 1 then "row" else "rows" in
  Printf.sprintf "%s %d %s" verb affected_rows noun

(* Translate [logical] inside a brief read transaction so the catalog handle
   has a transaction to consult, then return the plan. The transaction closes
   before dispatch, so the subsequent Eval call opens its own transaction of
   the right permission. Translate is pure given its catalog callback, so it's
   safe to drop the read transaction between translate and eval. *)
let translate_plan environment logical =
  Storage.with_read_transaction environment (fun transaction ->
      let catalog table_name =
        Catalog.get environment transaction ~table_name
      in
      Translate.translate ~catalog logical)

(* Dispatch [plan] to the right Eval entry point inside a transaction of the
   right permission, and print the result. Query opens a read transaction and
   pretty-prints the relation as before; Mutation opens a write transaction
   and prints the affected-row status. Both arms read their dispatch decision
   off the same [Physical.plan] constructor, so the verb and the chosen entry
   are guaranteed consistent. *)
let dispatch_and_print environment ~output plan =
  match plan with
  | Physical.Query physical ->
      Storage.with_read_transaction environment (fun transaction ->
          Eval.eval environment transaction physical (fun relation ->
              Relation.print ~formatter:output relation))
  | Physical.Mutation mutation ->
      Storage.with_write_transaction environment (fun transaction ->
          let affected_rows =
            Eval.eval_mutation environment transaction mutation
          in
          Format.fprintf output "%s@."
            (format_mutation_status mutation affected_rows))

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
    let plan = translate_plan environment logical in
    if show_physical then Physical.format_plan output plan;
    dispatch_and_print environment ~output plan
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
