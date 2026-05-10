(** Database values.

    [Value.t] is a runtime value -- one of the v1 supported types carrying its
    payload. [Kind.t] is the static tag used in schemas to declare the type of a
    column. The two are deliberately separated so schemas can be described
    without committing to any particular value, and so the constructors don't
    clash. *)

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

val kind_of : t -> Kind.t
(** [kind_of value] returns the static {!Kind.t} that classifies [value]. Used
    when checking that two terms in a comparison have agreeing kinds. *)
