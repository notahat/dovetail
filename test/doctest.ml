(** Doctest extractor and verifier for markdown files containing REPL sessions.

    A fenced code block (triple-backtick) is treated as a REPL session if and
    only if its first non-blank line starts with [> ]. Inside a session, every
    line starting with [> ] is a query; the lines that follow (up to the next
    [> ] or the end of the block) are the expected rendered output of that
    query.

    Fenced blocks that don't start with [> ] -- shell snippets, OCaml code,
    ASCII diagrams -- pass through untouched. The convention is unambiguous
    against Dovetail query syntax: no real query line ever begins with [> ], so
    a leading prompt reliably marks a REPL session.

    Verification runs the extracted queries through {!Repl.run} against a
    caller-supplied environment, splits the captured output back into one
    segment per query, and compares each segment to its documented expected
    output. The comparison ignores a single trailing newline on either side (the
    formatter emits one; copy-pasting into markdown doesn't always preserve it).

    A line in expected output consisting of just [...] (after stripping
    surrounding whitespace) is a truncation marker. When the last non-blank line
    of expected output is the marker, the comparator only checks that actual
    output begins with the lines preceding the marker -- anything that follows
    in actual is accepted. This lets the doc show the first few rows of a long
    table without committing to verify the whole thing. *)

open Dovetail

type query = { source : string; expected_output : string }
type session = { block_starts_at_line : int; queries : query list }

type error = {
  block_starts_at_line : int;
  query : query;
  actual_output : string;
}

(* === Markdown parsing === *)

let fence_marker = "```"
let prompt_marker = "> "

(** [starts_with prefix string] is [true] when [string] begins with [prefix]. *)
let starts_with prefix string =
  let prefix_length = String.length prefix in
  String.length string >= prefix_length
  && String.sub string 0 prefix_length = prefix

(** Markdown fence lines start with three (or more) backticks; the rest of the
    line is the optional language tag and is ignored here. *)
let is_fence line = starts_with fence_marker line

(** The convention: a block is a session iff its first non-blank line opens with
    the REPL prompt. *)
let first_non_blank_starts_with_prompt lines =
  match List.find_opt (fun line -> String.trim line <> "") lines with
  | None -> false
  | Some line -> starts_with prompt_marker line

type pending_query = { source : string; output_lines_reversed : string list }
(** A query whose expected-output lines are still being accumulated. The lines
    are stored in reverse order; the fold reverses them at completion time. *)

(** Close out [pending] (if any) by reversing its output lines and prepending
    the finished {!query} to [queries]. *)
let finish_pending_query pending queries =
  match pending with
  | None -> queries
  | Some { source; output_lines_reversed } ->
      let expected_output =
        if output_lines_reversed = [] then ""
        else String.concat "\n" (List.rev output_lines_reversed) ^ "\n"
      in
      { source; expected_output } :: queries

(** Walk a session's body lines, collecting [(source, expected_output)] pairs.
    Lines before the first prompt are dropped; once a prompt is seen, subsequent
    lines accumulate as that query's expected output until the next prompt or
    end of block. *)
let parse_session_lines lines =
  let prompt_length = String.length prompt_marker in
  let process_line (pending, queries) line =
    if starts_with prompt_marker line then
      let source =
        String.sub line prompt_length (String.length line - prompt_length)
      in
      ( Some { source; output_lines_reversed = [] },
        finish_pending_query pending queries )
    else
      match pending with
      | None -> (None, queries)
      | Some { source; output_lines_reversed } ->
          ( Some
              { source; output_lines_reversed = line :: output_lines_reversed },
            queries )
  in
  let final_pending, queries = List.fold_left process_line (None, []) lines in
  List.rev (finish_pending_query final_pending queries)

(** Split [text] into lines, preserving a trailing empty when [text] ends with a
    newline (so line numbering matches the source file). *)
let split_lines text = String.split_on_char '\n' text

(** Where the line-by-line walk is in its alternation between prose and fenced
    blocks. [Inside_block] carries the source line at which the opening fence
    appeared (so the session can report it) and the accumulated body lines in
    reverse order. *)
type extractor_state =
  | Outside
  | Inside_block of { block_starts_at_line : int; lines_reversed : string list }

(** Close out the current block: if its body opens with a prompt, parse it as a
    session and prepend; either way, return to [Outside]. *)
let close_block ~block_starts_at_line ~lines_reversed sessions =
  let body = List.rev lines_reversed in
  if first_non_blank_starts_with_prompt body then
    let queries = parse_session_lines body in
    { block_starts_at_line; queries } :: sessions
  else sessions

(** Walk [markdown] line by line, alternating in/out of fenced blocks. On each
    block close, if its body opens with a prompt, parse it as a session.
    Unterminated final blocks are silently dropped -- mirroring markdown
    rendering, which would do the same. *)
let extract_sessions markdown =
  let process_line (state, sessions) (line_index, line) =
    let line_number = line_index + 1 in
    match (is_fence line, state) with
    | true, Outside ->
        ( Inside_block
            { block_starts_at_line = line_number; lines_reversed = [] },
          sessions )
    | true, Inside_block { block_starts_at_line; lines_reversed } ->
        (Outside, close_block ~block_starts_at_line ~lines_reversed sessions)
    | false, Outside -> (Outside, sessions)
    | false, Inside_block { block_starts_at_line; lines_reversed } ->
        ( Inside_block
            { block_starts_at_line; lines_reversed = line :: lines_reversed },
          sessions )
  in
  let numbered_lines =
    List.mapi (fun index line -> (index, line)) (split_lines markdown)
  in
  let _final_state, sessions =
    List.fold_left process_line (Outside, []) numbered_lines
  in
  List.rev sessions

(* === Verification === *)

(** Feed every query's source line into {!Repl.run} against [environment],
    capturing all formatter output into a single string. *)
let capture_repl_output environment queries =
  let lines = List.map (fun (query : query) -> query.source) queries in
  Test_helpers.with_captured_formatter @@ fun formatter ->
  Repl.run environment
    ~read_line:(Test_helpers.read_line_from_list lines)
    ~output:formatter

(** [find_substring needle haystack ~from] returns the smallest index [>= from]
    at which [needle] occurs in [haystack], or [None]. Used by {!split_outputs}
    -- [String] doesn't expose a multi-character search and the split shape is
    cleaner against an index helper than against a hand-rolled scanner. *)
let find_substring needle haystack ~from =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec scan position =
    if position + needle_length > haystack_length then None
    else if String.sub haystack position needle_length = needle then
      Some position
    else scan (position + 1)
  in
  scan from

(** Split [body] on every occurrence of [separator]. The result has one more
    element than the number of separator occurrences; empty segments at the
    boundaries are preserved. *)
let split_on_substring ~separator body =
  let separator_length = String.length separator in
  let body_length = String.length body in
  let rec collect start =
    match find_substring separator body ~from:start with
    | None -> [ String.sub body start (body_length - start) ]
    | Some position ->
        String.sub body start (position - start)
        :: collect (position + separator_length)
  in
  collect 0

(** Split a captured REPL stream into one segment per query.

    The stream looks like:

    {v
    > <output of query 1>
    > <output of query 2>
    ...
    > <output of query N>
    >
    v}

    The first prompt has no preceding newline; every later prompt does. The
    final prompt comes from the EOF read and has nothing after it. So stripping
    the leading prompt and splitting on ["\n> "] yields N+1 chunks, the last of
    which is empty -- and that trailing empty is dropped. *)
let split_outputs captured =
  let prompt_length = String.length prompt_marker in
  if
    String.length captured < prompt_length
    || String.sub captured 0 prompt_length <> prompt_marker
  then
    failwith
      (Printf.sprintf
         "doctest: captured REPL output did not start with a prompt: %S"
         captured);
  let body =
    String.sub captured prompt_length (String.length captured - prompt_length)
  in
  let separator = "\n" ^ prompt_marker in
  let segments = split_on_substring ~separator body in
  match List.rev segments with "" :: rest -> List.rev rest | _ -> segments

let truncation_marker = "..."

(** Detect a trailing truncation marker line in [expected]. Returns the prefix
    of [expected] up to (but excluding) the marker line if the marker is
    present, otherwise [None]. Whitespace-only lines after the marker are
    ignored when locating it; the marker itself must be on its own line. *)
let split_truncation_marker expected =
  let lines = String.split_on_char '\n' expected in
  let rec find_marker reversed_remaining =
    match reversed_remaining with
    | [] -> None
    | line :: rest when String.trim line = "" -> find_marker rest
    | line :: rest when String.trim line = truncation_marker -> Some rest
    | _ -> None
  in
  match find_marker (List.rev lines) with
  | None -> None
  | Some reversed_prefix_lines ->
      let prefix_lines = List.rev reversed_prefix_lines in
      let prefix = String.concat "\n" prefix_lines in
      let prefix_with_newline = if prefix = "" then "" else prefix ^ "\n" in
      Some prefix_with_newline

(** Compare actual REPL output to documented expected output.

    With no truncation marker: byte-for-byte equality after collapsing a single
    trailing newline on either side.

    With a trailing [...] marker: actual need only begin with the lines
    preceding the marker. *)
let outputs_match actual expected =
  match split_truncation_marker expected with
  | Some prefix -> starts_with prefix actual
  | None ->
      let strip_trailing_newline text =
        let length = String.length text in
        if length > 0 && text.[length - 1] = '\n' then
          String.sub text 0 (length - 1)
        else text
      in
      strip_trailing_newline actual = strip_trailing_newline expected

(** Run one session and return the first mismatch, if any. *)
let verify_session environment session =
  let actual_outputs =
    split_outputs (capture_repl_output environment session.queries)
  in
  let actual_count = List.length actual_outputs in
  let query_count = List.length session.queries in
  if actual_count <> query_count then
    failwith
      (Printf.sprintf
         "doctest: query count (%d) and captured output count (%d) disagree"
         query_count actual_count);
  let rec loop queries actuals =
    match (queries, actuals) with
    | [], [] -> Ok ()
    | query :: query_rest, actual :: actual_rest ->
        if outputs_match actual query.expected_output then
          loop query_rest actual_rest
        else
          Error
            {
              block_starts_at_line = session.block_starts_at_line;
              query;
              actual_output = actual;
            }
    | _ -> assert false
  in
  loop session.queries actual_outputs

let verify_sessions environment sessions =
  let rec loop = function
    | [] -> Ok ()
    | session :: rest -> (
        match verify_session environment session with
        | Ok () -> loop rest
        | Error error -> Error error)
  in
  loop sessions

let read_file path = In_channel.with_open_text path In_channel.input_all

let verify_file environment ~markdown_path =
  let markdown = read_file markdown_path in
  let sessions = extract_sessions markdown in
  verify_sessions environment sessions

let format_error ~markdown_path error =
  Printf.sprintf
    "%s: doctest mismatch in block starting at line %d\n\
     query: %s\n\
     --- expected ---\n\
     %s--- actual ---\n\
     %s"
    markdown_path error.block_starts_at_line error.query.source
    error.query.expected_output error.actual_output
