(* The catalog tables that {!script} populates. Hardcoded alongside the
   script so the idempotency check can short-circuit without parsing
   the statements; if [script] grows to add a third table this list
   must grow with it. *)
let demo_tables = [ "users"; "orders" ]

let script =
  [
    ":create table users (id: Int64, name: String, email: String, active: \
     Bool) primary key (id)";
    "{id: 1, name: \"Alice\", email: \"alice@example.com\", active: true} | \
     insert into users";
    "{id: 2, name: \"Bob\", email: \"bob@example.com\", active: false} | \
     insert into users";
    "{id: 3, name: \"Carol\", email: \"carol@example.com\", active: true} | \
     insert into users";
    "{id: 4, name: \"Dave\", email: \"dave@example.com\", active: true} | \
     insert into users";
    "{id: 5, name: \"Eve\", email: \"eve@example.com\", active: false} | \
     insert into users";
    ":create table orders (id: Int64, user_id: Int64, description: String, \
     amount: Int64) primary key (id)";
    "{id: 1, user_id: 1, description: \"Coffee\", amount: 5} | insert into \
     orders";
    "{id: 2, user_id: 1, description: \"Bagel\", amount: 4} | insert into \
     orders";
    "{id: 3, user_id: 2, description: \"Tea\", amount: 3} | insert into orders";
    "{id: 4, user_id: 3, description: \"Sandwich\", amount: 8} | insert into \
     orders";
    "{id: 5, user_id: 3, description: \"Cake\", amount: 6} | insert into orders";
    "{id: 6, user_id: 5, description: \"Cookie\", amount: 2} | insert into \
     orders";
  ]

(* True when every name in {!demo_tables} is already present in the
   catalog. A partial state -- some tables present, others not --
   reads as "not seeded", so [run] replays the script; replay then
   fails on whichever table already exists, surfacing the partial
   state rather than silently leaving it. *)
let already_seeded environment =
  Storage.with_read_transaction environment (fun transaction ->
      List.for_all
        (fun table_name ->
          Option.is_some (Catalog.get environment transaction ~table_name))
        demo_tables)

(* A [unit -> string option] callback that yields successive entries
   of [lines] and then [None] forever, matching the EOF-as-[None]
   contract {!Repl.run} expects of stdin. *)
let read_line_from_list lines =
  let remaining = ref lines in
  fun () ->
    match !remaining with
    | [] -> None
    | head :: rest ->
        remaining := rest;
        Some head

(* True if [line] starts with one of the prefixes the REPL uses for
   per-line failures. The REPL catches [Failure] and parser errors
   inside [process_line] and writes them to [output] as [error: ...]
   or [parse error: ...] rather than raising, so a script bug would
   otherwise be invisible to [run]. *)
let line_indicates_error line =
  let has_prefix prefix =
    String.length line >= String.length prefix
    && String.sub line 0 (String.length prefix) = prefix
  in
  has_prefix "error:" || has_prefix "parse error:"

(* Walk the captured REPL output and raise on the first error line.
   Naming the offending line in the failure means a broken script
   element shows up in test output as "Demo_data: error: ..." with
   enough detail to find the bad statement. *)
let raise_on_script_failure buffer =
  let lines = String.split_on_char '\n' (Buffer.contents buffer) in
  match List.find_opt line_indicates_error lines with
  | None -> ()
  | Some offending_line -> failwith ("Demo_data: " ^ offending_line)

let run environment =
  if already_seeded environment then ()
  else
    let buffer = Buffer.create 256 in
    let output = Format.formatter_of_buffer buffer in
    Repl.run environment ~read_line:(read_line_from_list script) ~output;
    Format.pp_print_flush output ();
    raise_on_script_failure buffer
