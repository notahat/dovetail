let table_subdb_name table = "table:" ^ table

(* Look up the schema and storage handle for a table referenced in a plan.
   Raises [Failure] if the catalog has no schema for [table], or if the
   catalog has a schema but no storage subDB exists. *)
let lookup_table_resources environment transaction table =
  let schema =
    match Catalog.get environment transaction ~table_name:table with
    | Some schema -> schema
    | None -> failwith (Printf.sprintf "Eval: unknown table %S" table)
  in
  let table_map =
    match
      Storage.open_map environment transaction ~name:(table_subdb_name table)
    with
    | Some map -> map
    | None ->
        failwith
          (Printf.sprintf
             "Eval: catalog has schema for %S but no storage subDB exists" table)
  in
  (schema, table_map)

(* A binding operator for CPS-shaped actions. [let* x = action in body]
   desugars to [( let* ) action (fun x -> body)], which here is just
   [action (fun x -> body)] -- the operator is the identity. It exists
   purely to flatten the nested continuations: every [eval ...] and
   [Storage.with_iter_seq ...] in this module takes a final continuation
   argument, so partially applying everything except that argument yields
   exactly the [(value -> 'a) -> 'a] shape that [let*] binds. *)
let ( let* ) action continue = action continue

(* Open the cursor for the duration of [continue] and hand it a relation
   whose tuples are pulled lazily from the live cursor. *)
let evaluate_full_scan environment transaction table continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  let* pairs = Storage.with_iter_seq table_map transaction in
  let tuples = Seq.map (Row_codec.decode_row schema) pairs in
  continue ({ schema; tuples } : [ `Bag ] Relation.t)

(* Encode [key], probe the table's storage subDB with [Storage.get], and
   hand [continue] a relation whose [tuples] seq has either one element
   (the decoded row) or zero (no row at that key). The seq is [Seq.empty]
   or [Seq.return _] -- a regular OCaml seq, not a live cursor -- so there
   is no resource scope to keep open across [continue]; the relation can
   safely be consumed at any point. *)
let evaluate_index_lookup environment transaction ~table ~key continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  let encoded_key = Encoding.encode_int64_key key in
  let tuples =
    match Storage.get table_map transaction ~key:encoded_key with
    | None -> Seq.empty
    | Some value_bytes ->
        Seq.return (Row_codec.decode_row schema (encoded_key, value_bytes))
  in
  continue ({ schema; tuples } : [ `Bag ] Relation.t)

(* CPS-shaped executor. Every operator is in continuation-passing form so
   the consumer's [continue] runs inside whatever cursor and resource
   scopes the plan opens, letting tuples stream directly from live
   cursors rather than being eagerly materialised. *)
let rec eval environment transaction plan continue =
  match (plan : Physical.t) with
  | FullScan { table } ->
      evaluate_full_scan environment transaction table continue
  | Filter { input; predicate } ->
      evaluate_filter environment transaction ~input ~predicate continue
  | Project { input; columns } ->
      evaluate_project environment transaction ~input ~columns continue
  | CrossProduct { left; right } ->
      evaluate_cross_product environment transaction ~left ~right continue
  | IndexLookup { table; key } ->
      evaluate_index_lookup environment transaction ~table ~key continue
  | NestedLoopJoin { left; right; predicate } ->
      evaluate_nested_loop_join environment transaction ~left ~right ~predicate
        continue
  | IndexedNestedLoopJoin
      { outer; inner_table; outer_key_column; inner_position } ->
      evaluate_indexed_nested_loop_join environment transaction ~outer
        ~inner_table ~outer_key_column ~inner_position continue

(* Stream the input through [eval], then wrap its tuple seq in a
   [Seq.filter] guarded by the resolved predicate. The schema is unchanged.
   Resolution happens inside the input's scope so type errors still surface
   before any tuples are pulled. *)
and evaluate_filter environment transaction ~input ~predicate continue =
  let* input_relation = eval environment transaction input in
  let evaluate_predicate = Expression.resolve input_relation.schema predicate in
  continue
    {
      schema = input_relation.schema;
      tuples = Seq.filter evaluate_predicate input_relation.tuples;
    }

(* Stream the input through [eval], then wrap its tuple seq in a [Seq.map]
   that projects each row to the requested columns. The projected schema
   is computed eagerly inside the input's scope so column-resolution
   errors surface before any tuples are pulled. *)
and evaluate_project environment transaction ~input ~columns continue =
  let* input_relation = eval environment transaction input in
  let projected_schema, project_tuple =
    Projection.resolve input_relation.schema columns
  in
  continue
    {
      schema = projected_schema;
      tuples = Seq.map project_tuple input_relation.tuples;
    }

(* Sequence the left scope and then the right scope via [let*]; the body
   below runs inside both. The right side is materialised via [List.of_seq]
   because the outer loop over left tuples re-iterates it -- a one-shot
   streaming seq can't be replayed, and streaming both sides would require
   a different join algorithm (hash, merge). *)
and evaluate_cross_product environment transaction ~left ~right continue =
  let* left_relation = eval environment transaction left in
  let* right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.tuples in
  let combined_schema : Schema.t =
    {
      fields = left_relation.schema.fields @ right_relation.schema.fields;
      primary_key = [];
    }
  in
  let combined_tuples =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.map (fun right_tuple -> Array.append left_tuple right_tuple))
      left_relation.tuples
  in
  continue { schema = combined_schema; tuples = combined_tuples }

(* Resolve [outer_key_column] against the outer relation's schema and
   verify that the resolved field is the [Int64] kind required by the
   inner's primary-key encoding. Raises [Failure] on either resolution
   failure or a kind mismatch. Returns the column's zero-based position
   in an outer tuple. *)
and resolve_int64_outer_key_position outer_schema outer_key_column =
  let position, field =
    match Schema.find_field outer_schema outer_key_column with
    | Ok result -> result
    | Error message ->
        failwith
          (Printf.sprintf "Eval: IndexedNestedLoopJoin outer key column: %s"
             message)
  in
  match field.kind with
  | Int64 -> position
  | other_kind ->
      failwith
        (Printf.sprintf
           "Eval: IndexedNestedLoopJoin requires Int64 outer key column, got \
            %s for %S"
           (Value.Kind.to_string other_kind)
           (Schema.format_column_reference outer_key_column))

(* Stream the [outer] sub-plan and probe [inner_table]'s storage by the
   outer tuple's value at [outer_key_column]. Each outer tuple yields
   one combined row when the probe hits, and is dropped when it misses.
   The combined schema and tuples are ordered by [inner_position]:
   [`Left] puts inner first, [`Right] puts outer first. *)
and evaluate_indexed_nested_loop_join environment transaction ~outer
    ~inner_table ~outer_key_column ~inner_position continue =
  let inner_schema, inner_table_map =
    lookup_table_resources environment transaction inner_table
  in
  let* outer_relation = eval environment transaction outer in
  let outer_key_position =
    resolve_int64_outer_key_position outer_relation.schema outer_key_column
  in
  let combined_fields =
    match inner_position with
    | `Left -> inner_schema.fields @ outer_relation.schema.fields
    | `Right -> outer_relation.schema.fields @ inner_schema.fields
  in
  let combined_schema : Schema.t =
    { fields = combined_fields; primary_key = [] }
  in
  let combine_tuples ~inner_tuple ~outer_tuple =
    match inner_position with
    | `Left -> Array.append inner_tuple outer_tuple
    | `Right -> Array.append outer_tuple inner_tuple
  in
  let probe_outer_tuple outer_tuple =
    match outer_tuple.(outer_key_position) with
    | Value.Int64 key -> (
        let encoded_key = Encoding.encode_int64_key key in
        match Storage.get inner_table_map transaction ~key:encoded_key with
        | None -> None
        | Some value_bytes ->
            let inner_tuple =
              Row_codec.decode_row inner_schema (encoded_key, value_bytes)
            in
            Some (combine_tuples ~inner_tuple ~outer_tuple))
    | _ ->
        (* [resolve_int64_outer_key_position] has already checked that the
           column's static kind is [Int64], so a tuple value of any other
           kind would be an internal invariant violation rather than user
           error. *)
        assert false
  in
  let combined_tuples =
    Seq.filter_map probe_outer_tuple outer_relation.tuples
  in
  continue { schema = combined_schema; tuples = combined_tuples }

(* Same shape as [evaluate_cross_product] -- left and right sequenced via
   [let*], right side materialised -- with the predicate resolved against
   the combined schema and evaluated per (left, right) pair before the
   combined tuple is emitted. *)
and evaluate_nested_loop_join environment transaction ~left ~right ~predicate
    continue =
  let* left_relation = eval environment transaction left in
  let* right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.tuples in
  let combined_schema : Schema.t =
    {
      fields = left_relation.schema.fields @ right_relation.schema.fields;
      primary_key = [];
    }
  in
  let evaluate_predicate = Expression.resolve combined_schema predicate in
  let combined_tuples =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.filter_map (fun right_tuple ->
            let combined = Array.append left_tuple right_tuple in
            if evaluate_predicate combined then Some combined else None))
      left_relation.tuples
  in
  continue { schema = combined_schema; tuples = combined_tuples }
