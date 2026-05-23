module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term
module Ddl = Dovetail_ddl
module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Surface_ra = Dovetail_surface_ra
module Execution = Dovetail_execution

let prompt = "> "

(* Translate [logical_plan] inside [transaction] and, when the matching
   [show_*] flag is true, dump the logical and/or chosen physical plan to
   [output] around the translate call. Both plans share one helper so the
   ordering (logical before physical, matching pipeline direction) lives in
   one place. *)
let translate_in environment transaction ~output ~show_logical ~show_physical
    logical_plan =
  if show_logical then Plan.Logical.format output logical_plan;
  let catalog table_name =
    Storage.Catalog.get environment transaction ~table_name
  in
  let physical_plan = Plan.Translate.translate ~catalog logical_plan in
  if show_physical then Plan.Physical.format output physical_plan;
  physical_plan

(* Translate [logical_plan] inside [transaction], evaluate the resulting
   physical plan, and pretty-print the relation to [output]. Insert plans
   produce a one-row [(insert_count : int64)] relation; query plans produce
   their result relation; both render the same way through [Relation.print]. *)
let print_result environment transaction ~output ~show_logical ~show_physical
    logical_plan =
  let physical_plan =
    translate_in environment transaction ~output ~show_logical ~show_physical
      logical_plan
  in
  Execution.Eval.eval environment transaction physical_plan (fun term ->
      Term.format output term)

(* Run a single parsed query against [environment] and pretty-print the
   result to [output]. The plan's required access picks the transaction
   kind (read when nothing writes, write when an [Insert] appears anywhere
   in the tree); translation happens inside the chosen transaction so the
   catalog lookup shares scope with evaluation. Two helpers rather than
   one because [with_read_transaction] and [with_write_transaction] carry
   different permission tags -- unifying them would need a rank-2 type
   trick the gain doesn't justify. *)
let evaluate_and_print environment ~output ~show_logical ~show_physical
    logical_plan =
  try
    match Plan.Logical.required_access logical_plan with
    | `Read ->
        Storage.Engine.with_read_transaction environment (fun transaction ->
            print_result environment transaction ~output ~show_logical
              ~show_physical logical_plan)
    | `Write ->
        Storage.Engine.with_write_transaction environment (fun transaction ->
            print_result environment transaction ~output ~show_logical
              ~show_physical logical_plan)
  with Failure message -> Format.fprintf output "error: %s@." message

(* Render the result of a read-only DDL statement to [output]. [Listed] is
   one table name per line, in cursor order; an empty catalog produces no
   output (the prompt that follows the call sits immediately after).
   [Described] prints the kind in canonical form via [Format.statement]
   on the [Statement.of_kind] adapter -- the same canonical form a
   future [:create table] takes, so the round-trip property holds. *)
let print_ddl_read_result ~output = function
  | Ddl.Statement.Listed names ->
      List.iter (fun name -> Format.fprintf output "%s@." name) names
  | Ddl.Statement.Described { table_name; kind } ->
      Format.fprintf output "%s@."
        (Ddl.Format.statement (Ddl.Statement.of_kind ~table_name kind))

(* Render the result of a write DDL statement to [output]. [Dropped] is
   the single status line [dropped table "<name>"]; quoting is explicit so
   the wording is consistent regardless of identifier shape. [Created]
   mirrors that shape: [created table "<name>"]. *)
let print_ddl_write_result ~output = function
  | Ddl.Statement.Dropped table_name ->
      Format.fprintf output "dropped table \"%s\"@." table_name
  | Ddl.Statement.Created table_name ->
      Format.fprintf output "created table \"%s\"@." table_name

(* Execute a DDL statement against [environment] and write the rendered
   result to [output]. Structural checks via [Statement.validate] run
   before the transaction opens, so a failing validate never pays the
   writer-lock cost for an error it could surface earlier. The classifier
   then picks the transaction kind, mirroring the
   [Logical.required_access] dispatch above for pipelines; [Failure] raised inside validate or inside
   [execute_*] lands in the [error: ...] line through the shared guard. *)
let execute_and_print_ddl environment ~output statement =
  try
    let () =
      match Ddl.Statement.validate statement with
      | Ok () -> ()
      | Error message -> failwith message
    in
    match Ddl.Statement.classify statement with
    | `Read ->
        Storage.Engine.with_read_transaction environment (fun transaction ->
            print_ddl_read_result ~output
              (Execution.Ddl_executor.execute_read environment transaction
                 statement))
    | `Write ->
        Storage.Engine.with_write_transaction environment (fun transaction ->
            print_ddl_write_result ~output
              (Execution.Ddl_executor.execute_write environment transaction
                 statement))
  with Failure message -> Format.fprintf output "error: %s@." message

(* Process one input line: parse, dispatch on the program universe (a
   relational pipeline goes through Lower / Translate / Eval; a DDL
   statement goes straight to [Ddl_executor.execute_*]), print. Parse and
   eval errors land in [output]; nothing is raised. *)
let process_line environment ~output ~show_logical ~show_physical line =
  match Surface_ra.Parser.parse line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok (Surface_ra.Ast.Pipeline plan) ->
      let logical_plan = Surface_ra.Lower.lower plan in
      evaluate_and_print environment ~output ~show_logical ~show_physical
        logical_plan
  | Ok (Surface_ra.Ast.Ddl statement) ->
      execute_and_print_ddl environment ~output statement

let run ?(show_logical = false) ?(show_physical = false) environment ~read_line
    ~output =
  let rec loop () =
    Format.fprintf output "%s" prompt;
    Format.pp_print_flush output ();
    match read_line () with
    | None -> ()
    | Some line ->
        if String.length (String.trim line) > 0 then
          process_line environment ~output ~show_logical ~show_physical line;
        loop ()
  in
  loop ()
