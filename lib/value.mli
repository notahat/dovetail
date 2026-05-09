(** Database values.

    Slice 1 only needs the kind enumeration: schemas declare a kind per field,
    but no actual values are read or written through this layer yet. The full
    [Value.t] union arrives in slice 1 step 4 with the fixture rows. *)

module Kind : sig
  type t =
    | Int64
    | String
    | Bool  (** The set of value types supported in v1. *)
end
