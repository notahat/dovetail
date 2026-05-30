module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term

(* CPS bind; see [Table_access] for the rationale. *)
let ( let* ) action continue = action continue

(* Resolve [outer_key_column] against the outer relation's row kind and
   verify that the resolved field is the [Int64] kind required by the
   inner's primary-key encoding. Raises [Failure] on either resolution
   failure or a kind mismatch. Returns the column's zero-based position
   in an outer row. *)
let resolve_int64_outer_key_position outer_row_kind outer_key_column =
  let position, field =
    match Row.find_field outer_row_kind outer_key_column with
    | Ok result -> result
    | Error message ->
        failwith (Printf.sprintf "Join: outer key column: %s" message)
  in
  match field.kind with
  | Int64 -> position
  | other_kind ->
      failwith
        (Printf.sprintf "Join: requires Int64 outer key column, got %s for %S"
           (Scalar.kind_to_string other_kind)
           (Row.format_column_reference outer_key_column))

(* Stream the [outer] sub-plan and probe [inner_table]'s storage by the
   outer row's value at [outer_key_column]. Each outer row yields
   one combined row when the probe hits, and is dropped when it misses.
   The combined kind and rows are ordered by [inner_position]:
   [`Left] puts inner first, [`Right] puts outer first. *)
let evaluate ~eval_relation environment transaction ~outer ~inner_table
    ~outer_key_column ~inner_position continue =
  let inner_kind, inner_table_map =
    Table_access.lookup_table_resources environment transaction inner_table
  in
  let* (outer_relation : [ `Set | `Bag ] Relation.t) =
    eval_relation environment transaction outer
  in
  let outer_key_position =
    resolve_int64_outer_key_position outer_relation.kind.row_kind
      outer_key_column
  in
  let combined_row_kind =
    match inner_position with
    | `Left -> inner_kind.row_kind @ outer_relation.kind.row_kind
    | `Right -> outer_relation.kind.row_kind @ inner_kind.row_kind
  in
  let combined_kind : Relation.kind =
    { row_kind = combined_row_kind; refinements = [] }
  in
  let combine_rows ~inner_row ~outer_row =
    match inner_position with
    | `Left -> Array.append inner_row outer_row
    | `Right -> Array.append outer_row inner_row
  in
  let probe_outer_row outer_row =
    match outer_row.(outer_key_position) with
    | Scalar.Int64 key -> (
        let encoded_key = Storage.Encoding.encode_int64_key key in
        match
          Storage.Engine.get inner_table_map transaction ~key:encoded_key
        with
        | None -> None
        | Some value_bytes ->
            let inner_row =
              Storage.Row_codec.decode_row inner_kind (encoded_key, value_bytes)
            in
            Some (combine_rows ~inner_row ~outer_row))
    | _ ->
        (* [resolve_int64_outer_key_position] has already checked that the
           column's static kind is [Int64], so a row value of any other
           kind would be an internal invariant violation rather than user
           error. *)
        assert false
  in
  let combined_value = Seq.filter_map probe_outer_row outer_relation.value in
  continue
    (Term.Relation_value
       ({ kind = combined_kind; value = combined_value }
         : [ `Set | `Bag ] Relation.t))
