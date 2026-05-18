module Relation = Dovetail_core.Relation
module Ddl = Dovetail_ddl

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

(* Inside a read transaction: translate the plan, evaluate the relation it
   produces, and pretty-print the rows to [output]. The [Mutation] arm is
   unreachable -- [Logical.classify] chose [`Read] and so [Translate.translate]
   is contracted to return a [Physical.Query]. *)
let print_query_result environment transaction ~output ~show_physical
    logical_plan =
  match
    translate_in environment transaction ~output ~show_physical logical_plan
  with
  | Physical.Query physical ->
      Eval.eval environment transaction physical (fun relation ->
          Relation.print ~formatter:output relation)
  | Physical.Mutation _ -> assert false

(* Inside a write transaction: translate the plan, evaluate the mutation,
   and emit the affected-rows status line to [output]. The [Query] arm is
   unreachable for the symmetric reason -- [Logical.classify] chose [`Write]
   and so [Translate.translate] is contracted to return a [Physical.Mutation].
*)
let print_mutation_result environment transaction ~output ~show_physical
    logical_plan =
  match
    translate_in environment transaction ~output ~show_physical logical_plan
  with
  | Physical.Mutation mutation ->
      Eval.eval_mutation environment transaction mutation (fun affected_rows ->
          Format.fprintf output "%s@."
            (format_mutation_status mutation affected_rows))
  | Physical.Query _ -> assert false

(* Run a single parsed query against [environment] and pretty-print the
   result to [output]. The plan's classification picks the transaction kind
   (read for queries, write for mutations); translation happens inside the
   chosen transaction so the catalog lookup shares scope with evaluation.
   Two helpers rather than one because [with_read_transaction] and
   [with_write_transaction] carry different permission tags -- unifying them
   would need a rank-2 type trick the gain doesn't justify. *)
let evaluate_and_print environment ~output ~show_physical logical_plan =
  try
    match Logical.classify logical_plan with
    | `Read ->
        Storage.with_read_transaction environment (fun transaction ->
            print_query_result environment transaction ~output ~show_physical
              logical_plan)
    | `Write ->
        Storage.with_write_transaction environment (fun transaction ->
            print_mutation_result environment transaction ~output ~show_physical
              logical_plan)
  with Failure message -> Format.fprintf output "error: %s@." message

(* Render the result of a read-only DDL statement to [output]. [Listed] is
   one table name per line, in cursor order; an empty catalog produces no
   output (the prompt that follows the call sits immediately after).
   [Described] prints the schema in canonical form via [Format.statement]
   on the [Statement.of_schema] adapter -- the same canonical form a
   future [:create table] takes, so the round-trip property holds. *)
let print_ddl_read_result ~output = function
  | Ddl.Statement.Listed names ->
      List.iter (fun name -> Format.fprintf output "%s@." name) names
  | Ddl.Statement.Described { table_name; schema } ->
      Format.fprintf output "%s@."
        (Ddl.Format.statement (Ddl.Statement.of_schema ~table_name schema))

(* Render the result of a write DDL statement to [output]. [Dropped] is
   the single status line [dropped table "<name>"]; quoting is explicit so
   the wording matches the slice-12 spec regardless of identifier shape.
   [Created] mirrors that shape: [created table "<name>"]. *)
let print_ddl_write_result ~output = function
  | Ddl.Statement.Dropped table_name ->
      Format.fprintf output "dropped table \"%s\"@." table_name
  | Ddl.Statement.Created table_name ->
      Format.fprintf output "created table \"%s\"@." table_name

(* Execute a DDL statement against [environment] and write the rendered
   result to [output]. Structural checks via [Statement.validate] run
   before the transaction opens, so a failing validate never pays the
   writer-lock cost for an error it could surface earlier. The classifier
   then picks the transaction kind, mirroring the [Logical.classify] split
   above for pipelines; [Failure] raised inside the validate step or
   inside [execute_*] lands in the [error: ...] line through the shared
   guard. *)
let execute_and_print_ddl environment ~output statement =
  try
    let () =
      match Ddl.Statement.validate statement with
      | Ok () -> ()
      | Error message -> failwith message
    in
    match Ddl.Statement.classify statement with
    | `Read ->
        Storage.with_read_transaction environment (fun transaction ->
            print_ddl_read_result ~output
              (Ddl_executor.execute_read environment transaction statement))
    | `Write ->
        Storage.with_write_transaction environment (fun transaction ->
            print_ddl_write_result ~output
              (Ddl_executor.execute_write environment transaction statement))
  with Failure message -> Format.fprintf output "error: %s@." message

(* Process one input line: parse, dispatch on the program universe (a
   relational pipeline goes through Lower / Translate / Eval; a DDL
   statement goes straight to [Ddl_executor.execute_*]), print. Parse and
   eval errors land in [output]; nothing is raised. *)
let process_line environment ~output ~show_physical line =
  match Parser.parse line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok (Ast.Pipeline plan) ->
      let logical_plan = Lower.lower plan in
      evaluate_and_print environment ~output ~show_physical logical_plan
  | Ok (Ast.Ddl statement) ->
      execute_and_print_ddl environment ~output statement

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
