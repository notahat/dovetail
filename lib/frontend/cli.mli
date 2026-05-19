(** Command-line argument parsing for the dovetail binary.

    The grammar is small enough that a hand-rolled walker is clearer than a CLI
    library dependency: a handful of boolean flags that may appear in any
    position, and an optional positional environment path. A repeated flag or a
    second positional path is a usage error. *)

type options = {
  show_logical : bool;
  show_physical : bool;
  demo_data : bool;
  environment_path : string;
}
(** Parsed argument set. [environment_path] is the directory the LMDB
    environment lives in; it defaults to {!default_environment_path} when no
    positional argument is given. [show_logical] becomes [true] only when
    [--show-logical] appears in the argument list; [show_physical] mirrors that
    for [--show-physical]. [demo_data] becomes [true] only when [--demo-data]
    appears in the argument list; the binary uses it to decide whether to seed
    the example tables on boot. *)

val default_environment_path : string
(** Path used when no positional argument is supplied -- a sibling directory of
    the binary's working directory, lazily created by [Storage]. *)

val show_logical_flag : string
(** The literal flag string [--show-logical], exposed so callers and tests don't
    have to restate it. *)

val show_physical_flag : string
(** The literal flag string [--show-physical], exposed so callers and tests
    don't have to restate it. *)

val demo_data_flag : string
(** The literal flag string [--demo-data], exposed so the binary's usage line
    can render it without restating the spelling. *)

val parse : string list -> (options, string) result
(** [parse arguments] walks [arguments] -- the argv list with the program name
    already stripped -- and returns either the parsed {!options} or a short
    error string naming the offending input. The caller is responsible for
    rendering the usage message and choosing the exit code; this module only
    decides what the arguments mean. *)
