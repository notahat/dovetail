module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term
module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Surface_ra = Dovetail_surface_ra
module Surface_sql = Dovetail_surface_sql
module Execution = Dovetail_execution

(* Which surface language the session speaks. One surface per REPL run,
   chosen at launch; there is no per-line auto-detection or mode command.
   [`Ra] is the relational-algebra surface, [`Sql] the SQL one. *)
type surface = [ `Ra | `Sql ]

(* Raised inside a transaction when [Typecheck] reports one or more
   user-facing errors. The transaction's exception path aborts cleanly and
   the outer [evaluate_and_print] catches and renders. Keeps a non-commit
   exit out of the storage API. *)
exception Typecheck_failed of Plan.Typecheck.error list

(* The prompt for each surface, so a transcript shows which language is
   live. *)
let prompt_for = function `Ra -> "> " | `Sql -> "sql> "

(* Parse [line] with the chosen surface's parser and lower the resulting
   AST to the shared logical IR. The two surfaces have distinct ASTs but
   lower to the same {!Plan.Logical.t}, so the result type unifies here even
   though the parse/lower pair differs by surface. *)
let parse_and_lower surface line =
  match surface with
  | `Ra -> Result.map Surface_ra.Lower.lower (Surface_ra.Parser.parse line)
  | `Sql -> Result.map Surface_sql.Lower.lower (Surface_sql.Parser.parse line)

(* Translate [logical_plan] inside [transaction] and, when the matching
   [show_*] flag is true, dump the logical and/or chosen physical plan to
   [output] around the translate call. Both plans share one helper so the
   ordering (logical before physical, matching pipeline direction) lives in
   one place. *)
let translate_in environment transaction ~output ~show_logical ~show_physical
    logical_plan =
  if show_logical then Plan.Logical.format output logical_plan;
  let catalog_snapshot =
    Storage.Catalog.snapshot_kind environment transaction
  in
  let logical_plan =
    match Plan.Typecheck.typecheck ~catalog:catalog_snapshot logical_plan with
    | Ok plan -> plan
    | Error errors -> raise (Typecheck_failed errors)
  in
  let catalog table_name =
    Storage.Catalog.get environment transaction ~table_name
  in
  let physical_plan = Plan.Translate.translate ~catalog logical_plan in
  if show_physical then Plan.Physical.format output physical_plan;
  physical_plan

(* Translate [logical_plan] inside [transaction], evaluate the resulting
   physical plan, and pretty-print the relation to [output]. Insert plans
   produce a one-row [(insert_count : int64)] relation; query plans produce
   their result relation; both render the same way through [Term.format]. *)
let print_result environment transaction ~output ~show_logical ~show_physical
    logical_plan =
  let physical_plan =
    translate_in environment transaction ~output ~show_logical ~show_physical
      logical_plan
  in
  Execution.Eval.eval environment transaction physical_plan (fun term ->
      Format.fprintf output "%a@\n" Term.format term)

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
  with
  | Failure message -> Format.fprintf output "error: %s@." message
  | Typecheck_failed errors ->
      List.iter
        (fun error ->
          Format.fprintf output "error: %s@." (Plan.Typecheck.render error))
        errors

(* Process one input line: parse and lower with [surface]'s pair, then
   evaluate and print. Parse and eval errors land in [output]; nothing is
   raised. *)
let process_line environment ~output ~show_logical ~show_physical ~surface line
    =
  match parse_and_lower surface line with
  | Error message -> Format.fprintf output "parse error: %s@." message
  | Ok logical_plan ->
      evaluate_and_print environment ~output ~show_logical ~show_physical
        logical_plan

let run ?(show_logical = false) ?(show_physical = false) ?(surface = `Ra)
    environment ~read_line ~output =
  let prompt = prompt_for surface in
  let rec loop () =
    Format.fprintf output "%s" prompt;
    Format.pp_print_flush output ();
    match read_line () with
    | None -> ()
    | Some line ->
        if String.length (String.trim line) > 0 then
          process_line environment ~output ~show_logical ~show_physical ~surface
            line;
        loop ()
  in
  loop ()
