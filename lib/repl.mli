(** Read-eval-print loop driving the full query pipeline.

    [run] reads lines from a caller-supplied source, parses each one with
    {!Parser}, lowers and translates the resulting AST, evaluates the physical
    plan inside a read transaction, and pretty-prints the relation to a
    caller-supplied formatter. Each line is one independent query; the loop
    continues across both parse errors and evaluation failures, so a bad query
    doesn't take the whole session down.

    The callback shape (rather than a hard-coded [stdin]/[stdout] pair) is
    deliberate: the binary in [bin/main.ml] passes adapters around standard
    streams, while tests pass list-backed and buffer-backed adapters to drive
    the loop in-process. *)

val run :
  Storage.environment ->
  read_line:(unit -> string option) ->
  output:Format.formatter ->
  unit
(** [run environment ~read_line ~output] drives the loop until [read_line]
    returns [None] (EOF). A prompt ([> ]) is emitted to [output] before each
    read. Empty or whitespace-only lines are skipped silently; non-empty lines
    that fail to parse, or that fail during evaluation, produce a one-line error
    to [output] and the loop continues. *)
