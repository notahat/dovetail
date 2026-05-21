(** Database values.

    [Value.t] is a runtime value -- one of the v1 supported types carrying its
    payload. [Kind.t] is the static tag used in schemas to declare the type of a
    column. The two are deliberately separated so schemas can be described
    without committing to any particular value, and so the constructors don't
    clash.

    {!format} is the canonical source-like renderer: bare digits for [Int64],
    double-quoted text (no escape) for [String], lowercase keywords for [Bool].
    It is intended for output where the value's boundary needs to be visible --
    pretty-printed expressions, error messages, test failure diffs. The table
    renderer in {!Relation} chooses bare strings (no quotes) for cell display
    instead; that is a presentational decision specific to the table view and
    deliberately diverges from this canonical form. *)

module Kind : sig
  type t =
    | Int64
    | String
    | Bool  (** The set of value types supported in v1. *)

  val to_string : t -> string
  (** Render a kind as a short capitalised name ([Int64], [String], [Bool]).
      Intended for type-mismatch error messages and EXPLAIN-style output. *)
end

(** A runtime value. Each constructor's name pairs with the same-named [Kind.t].
*)
type t = Int64 of int64 | String of string | Bool of bool

(** Framework-vocabulary aliases for the kind and data types. [kind] is the same
    type as [Kind.t] with the same constructors; [data] is the same type as [t]
    with the same constructors. Callers may use either form. The [Kind]
    submodule and bare [t] are scheduled for removal once consumers have
    migrated. *)
type kind = Kind.t = Int64 | String | Bool

type data = t = Int64 of int64 | String of string | Bool of bool

val kind_of : t -> Kind.t
(** [kind_of value] returns the static {!Kind.t} that classifies [value]. Used
    when checking that two terms in a comparison have agreeing kinds. *)

val kind_to_string : kind -> string
(** [kind_to_string kind] is the framework-vocabulary name for what
    {!Kind.to_string} does today: render a kind as a short capitalised name
    ([Int64], [String], [Bool]) for type-mismatch error messages and
    EXPLAIN-style output. *)

val format : Format.formatter -> t -> unit
(** [format formatter value] writes [value] to [formatter] in source-like form:
    [Int64] as bare digits (with leading [-] for negatives), [String] wrapped in
    double quotes with no escape processing, [Bool] as the lowercase keyword
    [true] or [false]. String values that contain a double quote do not
    round-trip through the parser today; the parser's literal grammar doesn't
    handle escapes either, so the two ends agree on the common case. *)

val to_string : t -> string
(** [to_string value] is [Format.asprintf "%a" format value]. Convenience for
    callers that want a string rather than a formatter target -- error messages,
    test diffs, single-value rendering. *)
