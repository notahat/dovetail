module Value = Dovetail_core.Value
module Schema = Dovetail_core.Schema
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Relation_literal = Dovetail_core.Relation_literal
module Storage = Dovetail_storage
module Plan = Dovetail_plan

(* Look up the schema and storage handle for a table referenced in a plan.
   Raises [Failure] if the catalog has no schema for [table], or if the
   catalog has a schema but no storage subDB exists. *)
let lookup_table_resources environment transaction table =
  let schema =
    match Storage.Catalog.get environment transaction ~table_name:table with
    | Some schema -> schema
    | None -> failwith (Printf.sprintf "Eval: unknown table %S" table)
  in
  let table_map =
    match
      Storage.Engine.open_map environment transaction
        ~name:(Storage.Catalog.table_subdb_name table)
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
   [Storage.Engine.with_iter_seq ...] in this module takes a final continuation
   argument, so partially applying everything except that argument yields
   exactly the [(value -> 'a) -> 'a] shape that [let*] binds. *)
let ( let* ) action continue = action continue

(* Open the cursor for the duration of [continue] and hand it a relation
   whose tuples are pulled lazily from the live cursor. *)
let evaluate_full_scan environment transaction table continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  let* pairs = Storage.Engine.with_iter_seq table_map transaction in
  let data = Seq.map (Storage.Row_codec.decode_row schema) pairs in
  let kind = Relation.kind_of_schema schema in
  continue ({ kind; data } : [ `Bag ] Relation.t)

(* Encode [key], probe the table's storage subDB with [Storage.Engine.get], and
   hand [continue] a relation whose [tuples] seq has either one element
   (the decoded row) or zero (no row at that key). The seq is [Seq.empty]
   or [Seq.return _] -- a regular OCaml seq, not a live cursor -- so there
   is no resource scope to keep open across [continue]; the relation can
   safely be consumed at any point. *)
let evaluate_index_lookup environment transaction ~table ~key continue =
  let schema, table_map =
    lookup_table_resources environment transaction table
  in
  let encoded_key = Storage.Encoding.encode_int64_key key in
  let data =
    match Storage.Engine.get table_map transaction ~key:encoded_key with
    | None -> Seq.empty
    | Some value_bytes ->
        Seq.return
          (Storage.Row_codec.decode_row schema (encoded_key, value_bytes))
  in
  let kind = Relation.kind_of_schema schema in
  continue ({ kind; data } : [ `Bag ] Relation.t)

(* Materialise a [RelationLiteral] as a [Relation.t]. The kind comes from
   {!Relation_literal.kind_of} -- the kind-inference rule lives there so
   {!Logical} and {!Physical}'s doc comments can point at it. The literal
   stays small enough that the rows can be produced eagerly via
   [List.to_seq] without any storage scope. *)
let evaluate_relation_literal ~columns ~rows continue =
  let first_row =
    match rows with
    | first :: _ -> first
    | [] -> failwith "Eval: relation literal must have at least one row"
  in
  if List.length first_row <> List.length columns then
    failwith
      (Printf.sprintf
         "Eval: relation literal row has %d value(s) but %d column(s) are \
          declared"
         (List.length first_row) (List.length columns));
  let kind = Relation_literal.kind_of ~columns ~first_row in
  let data = rows |> List.to_seq |> Seq.map Array.of_list in
  continue ({ kind; data } : [ `Bag ] Relation.t)

(* CPS-shaped executor. Every operator is in continuation-passing form so
   the consumer's [continue] runs inside whatever cursor and resource
   scopes the plan opens, letting tuples stream directly from live
   cursors rather than being eagerly materialised. *)
let rec eval environment transaction plan continue =
  match (plan : Plan.Physical.t) with
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
  | RelationLiteral { columns; rows } ->
      evaluate_relation_literal ~columns ~rows continue

(* Stream the input through [eval], then wrap its tuple seq in a
   [Seq.filter] guarded by the resolved predicate. The schema is unchanged.
   Resolution happens inside the input's scope so type errors still surface
   before any tuples are pulled. *)
and evaluate_filter environment transaction ~input ~predicate continue =
  let* input_relation = eval environment transaction input in
  let evaluate_predicate =
    Expression.resolve input_relation.kind.row_kind predicate
  in
  continue
    {
      kind = input_relation.kind;
      data = Seq.filter evaluate_predicate input_relation.data;
    }

(* Stream the input through [eval], then wrap its tuple seq in a [Seq.map]
   that projects each row to the requested columns. The projected schema
   is computed eagerly inside the input's scope so column-resolution
   errors surface before any tuples are pulled. *)
and evaluate_project environment transaction ~input ~columns continue =
  let* input_relation = eval environment transaction input in
  let projected_kind, project_row =
    Plan.Projection.resolve input_relation.kind columns
  in
  continue
    { kind = projected_kind; data = Seq.map project_row input_relation.data }

(* Sequence the left scope and then the right scope via [let*]; the body
   below runs inside both. The right side is materialised via [List.of_seq]
   because the outer loop over left tuples re-iterates it -- a one-shot
   streaming seq can't be replayed, and streaming both sides would require
   a different join algorithm (hash, merge). *)
and evaluate_cross_product environment transaction ~left ~right continue =
  let* left_relation = eval environment transaction left in
  let* right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.data in
  let combined_kind : Relation.kind =
    {
      row_kind = left_relation.kind.row_kind @ right_relation.kind.row_kind;
      refinements = [];
    }
  in
  let combined_data =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.map (fun right_tuple -> Array.append left_tuple right_tuple))
      left_relation.data
  in
  continue { kind = combined_kind; data = combined_data }

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
           (Value.kind_to_string other_kind)
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
  let outer_schema = Relation.schema_of_kind outer_relation.kind in
  let outer_key_position =
    resolve_int64_outer_key_position outer_schema outer_key_column
  in
  let combined_fields =
    match inner_position with
    | `Left -> inner_schema.fields @ outer_schema.fields
    | `Right -> outer_schema.fields @ inner_schema.fields
  in
  let combined_kind : Relation.kind =
    { row_kind = combined_fields; refinements = [] }
  in
  let combine_tuples ~inner_tuple ~outer_tuple =
    match inner_position with
    | `Left -> Array.append inner_tuple outer_tuple
    | `Right -> Array.append outer_tuple inner_tuple
  in
  let probe_outer_tuple outer_tuple =
    match outer_tuple.(outer_key_position) with
    | Value.Int64 key -> (
        let encoded_key = Storage.Encoding.encode_int64_key key in
        match
          Storage.Engine.get inner_table_map transaction ~key:encoded_key
        with
        | None -> None
        | Some value_bytes ->
            let inner_tuple =
              Storage.Row_codec.decode_row inner_schema
                (encoded_key, value_bytes)
            in
            Some (combine_tuples ~inner_tuple ~outer_tuple))
    | _ ->
        (* [resolve_int64_outer_key_position] has already checked that the
           column's static kind is [Int64], so a tuple value of any other
           kind would be an internal invariant violation rather than user
           error. *)
        assert false
  in
  let combined_data = Seq.filter_map probe_outer_tuple outer_relation.data in
  continue { kind = combined_kind; data = combined_data }

(* Same shape as [evaluate_cross_product] -- left and right sequenced via
   [let*], right side materialised -- with the predicate resolved against
   the combined schema and evaluated per (left, right) pair before the
   combined tuple is emitted. *)
and evaluate_nested_loop_join environment transaction ~left ~right ~predicate
    continue =
  let* left_relation = eval environment transaction left in
  let* right_relation = eval environment transaction right in
  let right_tuples = List.of_seq right_relation.data in
  let combined_kind : Relation.kind =
    {
      row_kind = left_relation.kind.row_kind @ right_relation.kind.row_kind;
      refinements = [];
    }
  in
  let evaluate_predicate =
    Expression.resolve combined_kind.row_kind predicate
  in
  let combined_data =
    Seq.flat_map
      (fun left_tuple ->
        List.to_seq right_tuples
        |> Seq.filter_map (fun right_tuple ->
            let combined = Array.append left_tuple right_tuple in
            if evaluate_predicate combined then Some combined else None))
      left_relation.data
  in
  continue { kind = combined_kind; data = combined_data }

(* The mutation entry below evaluates its [source] sub-plan through [eval]
   inside its own write-transaction scope, then writes the resulting tuples
   one per row. *)

(* For each target field, find the position in [source_schema] that supplies
   its value. Raises [Failure] if a target field has no matching source
   column. Source columns absent from the target are tolerated here;
   Translate-level validation rejects them upstream. *)
let build_source_position_map ~source_schema ~(target_schema : Schema.t) =
  List.map
    (fun (target_field : Schema.field) ->
      match
        Schema.find_field source_schema
          { qualifier = None; name = target_field.name }
      with
      | Ok (position, _source_field) -> position
      | Error _ ->
          failwith
            (Printf.sprintf
               "Eval: insert source is missing column %S required by target \
                schema"
               target_field.name))
    target_schema.fields

(* Reorder [source_tuple] into a tuple matching [target_schema]'s field
   order, by indexing through [position_map]. The map has one entry per
   target field, in target order, giving the source position for that
   field's value. *)
let project_to_target_order ~position_map source_tuple =
  Array.of_list
    (List.map
       (fun source_position -> source_tuple.(source_position))
       position_map)

(* Extract a human-readable string for the primary-key value of a tuple
   already projected to [target_schema]'s field order. Used only to build
   the PK-collision error message. *)
let primary_key_value_text (target_schema : Schema.t) target_tuple =
  match target_schema.primary_key with
  | [ primary_key_name ] -> (
      match
        Schema.find_field target_schema
          { qualifier = None; name = primary_key_name }
      with
      | Ok (position, _field) -> Value.to_string target_tuple.(position)
      (* Internal invariant: by the time we're rendering an error for a row
         we just encoded, the PK column is in the schema. *)
      | Error _ -> assert false)
  (* TODO(composite-pk): render multi-column PKs once they are supported.
     For now no schema in the codebase has one. *)
  | _ -> "?"

(* Encode one source row in target form, fail on PK collision, else write
   it. *)
let insert_one_row ~target_schema ~target_map ~target_table ~write_transaction
    ~position_map source_tuple =
  let target_tuple = project_to_target_order ~position_map source_tuple in
  let key_bytes, value_bytes =
    Storage.Row_codec.encode_row target_schema target_tuple
  in
  (match Storage.Engine.get target_map write_transaction ~key:key_bytes with
  | None -> ()
  | Some _ ->
      failwith
        (Printf.sprintf
           "Eval: insert into %S: row with primary key %s already exists"
           target_table
           (primary_key_value_text target_schema target_tuple)));
  Storage.Engine.put target_map write_transaction ~key:key_bytes
    ~value:value_bytes

(* Evaluate the [source] sub-plan inside its own resource scope and write
   each tuple it produces into [target_table]. Returns the number of rows
   written via [continue]. *)
let evaluate_insert environment transaction ~target_table ~source continue =
  let target_schema, target_map =
    lookup_table_resources environment transaction target_table
  in
  let affected_rows = ref 0 in
  eval environment transaction source (fun source_relation ->
      let source_schema = Relation.schema_of_kind source_relation.kind in
      let position_map =
        build_source_position_map ~source_schema ~target_schema
      in
      Seq.iter
        (fun source_tuple ->
          insert_one_row ~target_schema ~target_map ~target_table
            ~write_transaction:transaction ~position_map source_tuple;
          incr affected_rows)
        source_relation.data);
  continue !affected_rows

let eval_mutation environment transaction mutation continue =
  match (mutation : Plan.Physical.mutation) with
  | Insert { table; source } ->
      evaluate_insert environment transaction ~target_table:table ~source
        continue
