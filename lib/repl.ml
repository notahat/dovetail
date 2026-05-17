let prompt = "> "

(* Render the affected-row status line for a completed mutation. The verb is
   keyed off the [mutation] constructor so the classifier and the rendered
   word come from the same source of truth: a future [Update]/[Delete] adds
   one constructor and one verb here and the rest of the renderer reuses. *)
let format_mutation_status mutation affected_rows =
  let verb = match mutation with Physical.Insert _ -> "inserted" in
  let noun = if affected_rows = 1 then "row" else "rows" in
  Printf.sprintf "%s %d %s" verb affected_rows noun

(* Translate [logical_plan] inside [transaction] and, when [show_physical] is
   true, dump the chosen physical plan to [output] before returning it. Pure
   helper threaded through both transaction arms below. *)
let translate_in environment transaction ~output ~show_physical logical_plan =
  let catalog table_name = Catalog.get environment transaction ~table_name in
  let physical_plan = Translate.translate ~catalog logical_plan in
  if show_physical then Physical.format_plan output physical_plan;
  physical_plan

(* Run a single parsed query against [environment] and pretty-print the
   result to [output]. The plan's classification picks the transaction kind:
   a [Query] opens a read transaction, a [Mutation] opens a write transaction.
   Translation happens inside the chosen transaction so the catalog lookup
   shares scope with evaluation, and the Physical wrapper's constructor
   re-decides the Eval entry point and the rendered verb at the dispatch
   site. The two arms duplicate scaffolding because their transaction perms
   differ -- with-with_*_transaction polymorphism would need a rank-2 type
   trick that the gain doesn't justify. The [failwith] branches assert the
   wrapper invariant ([Logical.Query] translates to [Physical.Query]; same
   for [Mutation]) explicitly rather than via [assert false]. *)
let evaluate_and_print environment ~output ~show_physical logical_plan =
  try
    match Logical.classify logical_plan with
    | `Read ->
        Storage.with_read_transaction environment (fun transaction ->
            match
              translate_in environment transaction ~output ~show_physical
                logical_plan
            with
            | Physical.Query physical ->
                Eval.eval environment transaction physical (fun relation ->
                    Relation.print ~formatter:output relation)
            | Physical.Mutation _ ->
                failwith
                  "internal error: Logical.Query translated to \
                   Physical.Mutation")
    | `Write ->
        Storage.with_write_transaction environment (fun transaction ->
            match
              translate_in environment transaction ~output ~show_physical
                logical_plan
            with
            | Physical.Mutation mutation ->
                let affected_rows =
                  Eval.eval_mutation environment transaction mutation
                in
                Format.fprintf output "%s@."
                  (format_mutation_status mutation affected_rows)
            | Physical.Query _ ->
                failwith
                  "internal error: Logical.Mutation translated to \
                   Physical.Query")
  with Failure message -> Format.fprintf output "error: %s@." message

(* Process one input line: parse, lower, evaluate, print. Parse and eval
   errors land in [output]; nothing is raised. *)
let process_line environment ~output ~show_physical line =
  match Parser.parse line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok ast ->
      let logical_plan = Lower.lower ast in
      evaluate_and_print environment ~output ~show_physical logical_plan

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
