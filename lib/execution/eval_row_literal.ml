module Row = Dovetail_core.Row
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term

(* Build a [Row.kind] from a row literal's [(reference, value)] pairs by
   reading each value's scalar kind. The qualifier on each reference rides
   through unchanged, so the bare form [(id = 1)] yields a field with
   [qualifier = None] and the qualified form [(users.id = 1)] yields one
   with [qualifier = Some "users"]. *)
let kind_of_fields fields : Row.kind =
  List.map
    (fun ((reference : Row.column_reference), value) : Row.field ->
      {
        name = reference.name;
        kind = Scalar.kind_of value;
        qualifier = reference.qualifier;
      })
    fields

(* Materialise a row literal as a [Row.t] and hand [continue] the
   [Term.Row_value] arm. The kind is derived eagerly from the values'
   scalar kinds; no storage is touched. *)
let evaluate fields continue =
  let kind = kind_of_fields fields in
  let value = Array.of_list (List.map snd fields) in
  continue (Term.Row_value ({ kind; value } : Row.t))
