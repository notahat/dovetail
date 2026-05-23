(** Database values.

    [Scalar.value] is a runtime value -- one of the v1 supported types carrying
    its payload. [Scalar.kind] is the static tag used in schemas to declare the
    type of a column. The two are deliberately separated so schemas can be
    described without committing to any particular value.

    The constructor names ([Int64], [String], [Bool]) are shared between the two
    types. OCaml's type-directed disambiguation picks the right one in nearly
    every realistic call site; the rare ambiguous position (a bare constructor
    in a list or tuple with no surrounding type) needs an annotation.

    {!format} is the canonical source-like renderer: bare digits for [Int64],
    double-quoted text (no escape) for [String], lowercase keywords for [Bool].
    It is intended for output where the value's boundary needs to be visible --
    pretty-printed expressions, error messages, test failure diffs. The table
    renderer in {!Relation} chooses bare strings (no quotes) for cell display
    instead; that is a presentational decision specific to the table view and
    deliberately diverges from this canonical form. *)

(** The static kind of a value, used in schemas to declare the type of a column.
*)
type kind = Int64 | String | Bool

(** A runtime value. *)
type value = Int64 of int64 | String of string | Bool of bool

val kind_of : value -> kind
(** [kind_of value] returns the static {!kind} that classifies [value]. Used
    when checking that two terms in a comparison have agreeing kinds. *)

val kind_to_string : kind -> string
(** Render a kind as a short capitalised name ([Int64], [String], [Bool]).
    Intended for type-mismatch error messages and EXPLAIN-style output. *)

val format : Format.formatter -> value -> unit
(** [format formatter value] writes [value] to [formatter] in source-like form:
    [Int64] as bare digits (with leading [-] for negatives), [String] wrapped in
    double quotes with no escape processing, [Bool] as the lowercase keyword
    [true] or [false]. String values that contain a double quote do not
    round-trip through the parser today; the parser's literal grammar doesn't
    handle escapes either, so the two ends agree on the common case. *)

val to_string : value -> string
(** [to_string value] is [Format.asprintf "%a" format value]. Convenience for
    callers that want a string rather than a formatter target -- error messages,
    test diffs, single-value rendering. *)
