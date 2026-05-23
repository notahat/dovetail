module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation
module Term = Dovetail_core.Term
module Storage = Dovetail_storage
module Plan = Dovetail_plan

(* Look up the kind and storage handle for a table referenced in a plan.
   Raises [Failure] if the catalog has no kind for [table], or if the catalog
   has a kind but no storage subDB exists. *)
let lookup_table_resources environment transaction table =
  let kind =
    match Storage.Catalog.get environment transaction ~table_name:table with
    | Some kind -> kind
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
             "Eval: catalog has kind for %S but no storage subDB exists" table)
  in
  (kind, table_map)

(* A binding operator for CPS-shaped actions. [let* x = action in body]
   desugars to [( let* ) action (fun x -> body)], which here is just
   [action (fun x -> body)] -- the operator is the identity. It exists
   purely to flatten the nested continuations: every [eval ...] and
   [Storage.Engine.with_iter_seq ...] in this module takes a final continuation
   argument, so partially applying everything except that argument yields
   exactly the [(value -> 'a) -> 'a] shape that [let*] binds. *)
let ( let* ) action continue = action continue

(* Open the cursor for the duration of [continue] and hand it a relation
   whose rows are pulled lazily from the live cursor. *)
let evaluate_full_scan environment transaction table continue =
  let kind, table_map = lookup_table_resources environment transaction table in
  let* pairs = Storage.Engine.with_iter_seq table_map transaction in
  let value = Seq.map (Storage.Row_codec.decode_row kind) pairs in
  continue (Term.Relation_value ({ kind; value } : [ `Bag ] Relation.t))

(* Encode [key], probe the table's storage subDB with [Storage.Engine.get], and
   hand [continue] a relation whose [value] seq has either one element
   (the decoded row) or zero (no row at that key). The seq is [Seq.empty]
   or [Seq.return _] -- a regular OCaml seq, not a live cursor -- so there
   is no resource scope to keep open across [continue]; the relation can
   safely be consumed at any point. *)
let evaluate_index_lookup environment transaction ~table ~key continue =
  let kind, table_map = lookup_table_resources environment transaction table in
  let encoded_key = Storage.Encoding.encode_int64_key key in
  let value =
    match Storage.Engine.get table_map transaction ~key:encoded_key with
    | None -> Seq.empty
    | Some value_bytes ->
        Seq.return
          (Storage.Row_codec.decode_row kind (encoded_key, value_bytes))
  in
  continue (Term.Relation_value ({ kind; value } : [ `Bag ] Relation.t))

(* CPS-shaped executor. Every operator is in continuation-passing form so
   the consumer's [continue] runs inside whatever cursor and resource
   scopes the plan opens, letting rows stream directly from live
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
  | Relation_literal { kind; rows } ->
      evaluate_relation_literal ~kind ~rows continue
  | Insert { table; source } ->
      evaluate_insert environment transaction ~target_table:table ~source
        continue
  | Type_op { input } ->
      evaluate_type_op environment transaction ~input continue
  | Scalar_literal value -> continue (Term.Scalar_value value)
  | Row_literal { fields } -> evaluate_row_literal fields continue

(* Compute [input]'s static kind and hand [continue] the corresponding
   [Term.*_kind] arm. A [Scalar_literal] input is dispatched directly to
   {!Scalar.kind_of}; every other shape is a relation, so the kind comes
   from {!Plan.Physical.kind_of}. No cursors are opened in either case.
   The catalog callback reads from the live [Storage.Catalog], so a
   missing-table reference inside [input] surfaces with the same wording
   the relational cases produce at scan time. *)
and evaluate_type_op environment transaction ~input continue =
  match input with
  | Plan.Physical.Scalar_literal value ->
      continue (Term.Scalar_kind (Scalar.kind_of value))
  | Plan.Physical.Row_literal { fields } ->
      continue (Term.Row_kind (row_kind_of_fields fields))
  | _ ->
      let catalog table_name =
        Storage.Catalog.get environment transaction ~table_name
      in
      let kind = Plan.Physical.kind_of ~catalog input in
      continue (Term.Relation_kind kind)

(* Build a [Row.kind] from a row literal's [(name, value)] pairs by reading
   each value's scalar kind. Field qualifiers have no surface form on a row
   literal, so every field carries [qualifier = None]. *)
and row_kind_of_fields fields : Row.kind =
  List.map
    (fun (name, value) : Row.field ->
      { name; kind = Scalar.kind_of value; qualifier = None })
    fields

(* Materialise a [Relation_literal] as a [Relation.t] using the kind declared
   up front. The empty form ([rows = []]) is valid because the kind doesn't
   depend on a first row. *)
and evaluate_relation_literal ~kind ~rows continue =
  let value = rows |> List.to_seq |> Seq.map Array.of_list in
  continue (Term.Relation_value ({ kind; value } : [ `Bag ] Relation.t))

(* Materialise a row literal as a [Row.t] and hand [continue] the
   [Term.Row_value] arm. The kind is derived eagerly from the values'
   scalar kinds; no storage is touched. *)
and evaluate_row_literal fields continue =
  let kind = row_kind_of_fields fields in
  let value = Array.of_list (List.map snd fields) in
  continue (Term.Row_value ({ kind; value } : Row.t))

(* CPS helper for internal recursion: a relational operator's sub-plan always
   produces a [Term.Relation_value]. The [Term.Relation_kind] arm only arises
   from the [Type_op] operator, which sits at the pipeline root and is never
   the input of another relational operator. *)
and eval_input environment transaction plan continue =
  eval environment transaction plan (function
    | Term.Relation_value relation -> continue relation
    | Term.Relation_kind _ | Term.Scalar_value _ | Term.Scalar_kind _
    | Term.Row_value _ | Term.Row_kind _ ->
        (* By construction relational sub-plans only ever produce relation
           values. Kinds arise from [Type_op]; the scalar and row arms have no
           constructors that wire into a relational sub-plan today. *)
        assert false)

(* Stream the input through [eval], then wrap its value seq in a [Seq.filter]
   guarded by the resolved predicate. The kind is unchanged. Resolution
   happens inside the input's scope so type errors still surface before any
   rows are pulled. *)
and evaluate_filter environment transaction ~input ~predicate continue =
  let* input_relation = eval_input environment transaction input in
  let evaluate_predicate =
    Expression.resolve input_relation.kind.row_kind predicate
  in
  continue
    (Term.Relation_value
       ({
          kind = input_relation.kind;
          value = Seq.filter evaluate_predicate input_relation.value;
        }
         : [ `Bag ] Relation.t))

(* Stream the input through [eval], then wrap its value seq in a [Seq.map] that
   projects each row to the requested columns. The projected kind is computed
   eagerly inside the input's scope so column-resolution errors surface before
   any rows are pulled. *)
and evaluate_project environment transaction ~input ~columns continue =
  let* input_relation = eval_input environment transaction input in
  let projected_kind, project_row =
    Plan.Projection.resolve input_relation.kind columns
  in
  continue
    (Term.Relation_value
       ({
          kind = projected_kind;
          value = Seq.map project_row input_relation.value;
        }
         : [ `Bag ] Relation.t))

(* Sequence the left scope and then the right scope via [let*]; the body
   below runs inside both. The right side is materialised via [List.of_seq]
   because the outer loop over left rows re-iterates it -- a one-shot
   streaming seq can't be replayed, and streaming both sides would require
   a different join algorithm (hash, merge). *)
and evaluate_cross_product environment transaction ~left ~right continue =
  let* left_relation = eval_input environment transaction left in
  let* right_relation = eval_input environment transaction right in
  let right_rows = List.of_seq right_relation.value in
  let combined_kind : Relation.kind =
    {
      row_kind = left_relation.kind.row_kind @ right_relation.kind.row_kind;
      refinements = [];
    }
  in
  let combined_value =
    Seq.flat_map
      (fun left_row ->
        List.to_seq right_rows
        |> Seq.map (fun right_row -> Array.append left_row right_row))
      left_relation.value
  in
  continue
    (Term.Relation_value
       ({ kind = combined_kind; value = combined_value } : [ `Bag ] Relation.t))

(* Resolve [outer_key_column] against the outer relation's row kind and
   verify that the resolved field is the [Int64] kind required by the
   inner's primary-key encoding. Raises [Failure] on either resolution
   failure or a kind mismatch. Returns the column's zero-based position
   in an outer row. *)
and resolve_int64_outer_key_position outer_row_kind outer_key_column =
  let position, field =
    match Row.find_field outer_row_kind outer_key_column with
    | Ok result -> result
    | Error message ->
        failwith
          (Printf.sprintf "Eval: IndexedNestedLoopJoin: outer key column: %s"
             message)
  in
  match field.kind with
  | Int64 -> position
  | other_kind ->
      failwith
        (Printf.sprintf
           "Eval: IndexedNestedLoopJoin: requires Int64 outer key column, got \
            %s for %S"
           (Scalar.kind_to_string other_kind)
           (Row.format_column_reference outer_key_column))

(* Stream the [outer] sub-plan and probe [inner_table]'s storage by the
   outer row's value at [outer_key_column]. Each outer row yields
   one combined row when the probe hits, and is dropped when it misses.
   The combined kind and rows are ordered by [inner_position]:
   [`Left] puts inner first, [`Right] puts outer first. *)
and evaluate_indexed_nested_loop_join environment transaction ~outer
    ~inner_table ~outer_key_column ~inner_position continue =
  let inner_kind, inner_table_map =
    lookup_table_resources environment transaction inner_table
  in
  let* outer_relation = eval_input environment transaction outer in
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
       ({ kind = combined_kind; value = combined_value } : [ `Bag ] Relation.t))

(* Same shape as [evaluate_cross_product] -- left and right sequenced via
   [let*], right side materialised -- with the predicate resolved against
   the combined row kind and evaluated per (left, right) pair before the
   combined row is emitted. *)
and evaluate_nested_loop_join environment transaction ~left ~right ~predicate
    continue =
  let* left_relation = eval_input environment transaction left in
  let* right_relation = eval_input environment transaction right in
  let right_rows = List.of_seq right_relation.value in
  let combined_kind : Relation.kind =
    {
      row_kind = left_relation.kind.row_kind @ right_relation.kind.row_kind;
      refinements = [];
    }
  in
  let evaluate_predicate =
    Expression.resolve combined_kind.row_kind predicate
  in
  let combined_value =
    Seq.flat_map
      (fun left_row ->
        List.to_seq right_rows
        |> Seq.filter_map (fun right_row ->
            let combined = Array.append left_row right_row in
            if evaluate_predicate combined then Some combined else None))
      left_relation.value
  in
  continue
    (Term.Relation_value
       ({ kind = combined_kind; value = combined_value } : [ `Bag ] Relation.t))

(* For each target field, find the position in [source_row_kind] that supplies
   its value. Raises [Failure] if a target field has no matching source
   column. Source columns absent from the target are tolerated here;
   Translate-level validation rejects them upstream. *)
and build_source_position_map ~target_table ~source_row_kind
    ~(target_kind : Relation.kind) =
  List.map
    (fun (target_field : Row.field) ->
      match
        Row.find_field source_row_kind
          { qualifier = None; name = target_field.name }
      with
      | Ok (position, _source_field) -> position
      | Error _ ->
          failwith
            (Printf.sprintf
               "Eval: insert into %S: source is missing column %S required by \
                target kind"
               target_table target_field.name))
    target_kind.row_kind

(* Reorder [source_row] into a row matching [target_kind]'s field order, by
   indexing through [position_map]. The map has one entry per target field, in
   target order, giving the source position for that field's value. *)
and project_to_target_order ~position_map source_row =
  Array.of_list
    (List.map
       (fun source_position -> source_row.(source_position))
       position_map)

(* Extract a human-readable string for the primary-key value of a row already
   projected to [target_kind]'s field order. Used only to build the
   PK-collision error message. *)
and primary_key_value_text (target_kind : Relation.kind) target_row =
  match Relation.primary_key_names target_kind with
  | [ primary_key_name ] -> (
      match
        Row.find_field target_kind.row_kind
          { qualifier = None; name = primary_key_name }
      with
      | Ok (position, _field) -> Scalar.to_string target_row.(position)
      (* Internal invariant: by the time we're rendering an error for a row
         we just encoded, the PK column is in the kind. *)
      | Error _ -> assert false)
  (* TODO(composite-pk): render multi-column PKs once they are supported.
     For now no kind in the codebase has one. *)
  | _ -> "?"

(* Encode one source row in target form, fail on PK collision, else write
   it. *)
and insert_one_row ~target_kind ~target_map ~target_table ~write_transaction
    ~position_map source_row =
  let target_row = project_to_target_order ~position_map source_row in
  let key_bytes, value_bytes =
    Storage.Row_codec.encode_row target_kind target_row
  in
  (match Storage.Engine.get target_map write_transaction ~key:key_bytes with
  | None -> ()
  | Some _ ->
      failwith
        (Printf.sprintf
           "Eval: insert into %S: row with primary key %s already exists"
           target_table
           (primary_key_value_text target_kind target_row)));
  Storage.Engine.put target_map write_transaction ~key:key_bytes
    ~value:value_bytes

(* The static row shape an insert reports: a one-column [insert_count : int64]
   row. The kind has no refinements -- the relation describes an evaluation
   result, not a stored table. *)
and insert_result_kind : Relation.kind =
  {
    row_kind =
      [ { name = "insert_count"; kind = Scalar.Int64; qualifier = None } ];
    refinements = [];
  }

(* Wrap a row count as the one-row [insert_count : int64] relation. *)
and insert_result_relation count : [ `Bag ] Relation.t =
  {
    kind = insert_result_kind;
    value = Seq.return [| Scalar.Int64 (Int64.of_int count) |];
  }

(* Evaluate the [source] sub-plan inside its own resource scope and write each
   row it produces into [target_table]. Hands [continue] a one-row relation
   reporting how many rows were written.

   [transaction] is widened to a write transaction here. The invariant that
   makes this sound: [Logical.required_access] reports [`Write] for any plan
   containing [Insert], and the REPL routes such plans through
   [Storage.Engine.with_write_transaction]. So whenever this branch runs,
   the LMDB handle really does have write permissions -- the phantom type
   is just lower-precision than the runtime. Same upstream-invariant
   pattern as the [assert false] arms elsewhere in the codebase. *)
and evaluate_insert environment transaction ~target_table ~source continue =
  let write_transaction : [ `Read | `Write ] Storage.Engine.transaction =
    Obj.magic transaction
  in
  let target_kind, target_map =
    lookup_table_resources environment write_transaction target_table
  in
  (* The row-write is the point of the iteration and the count is
     incidental; [Seq.iter] + [ref] expresses that more honestly than
     folding the count through a [Seq.fold_left] accumulator. *)
  let affected_rows = ref 0 in
  eval_input environment transaction source (fun source_relation ->
      let position_map =
        build_source_position_map ~target_table
          ~source_row_kind:source_relation.kind.row_kind ~target_kind
      in
      Seq.iter
        (fun source_row ->
          insert_one_row ~target_kind ~target_map ~target_table
            ~write_transaction ~position_map source_row;
          incr affected_rows)
        source_relation.value;
      continue (Term.Relation_value (insert_result_relation !affected_rows)))
