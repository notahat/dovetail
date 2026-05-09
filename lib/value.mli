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
end

(** A runtime value. Each constructor's name pairs with the same-named [Kind.t].
*)
type t = Int64 of int64 | String of string | Bool of bool
