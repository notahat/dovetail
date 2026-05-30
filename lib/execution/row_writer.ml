module Storage = Dovetail_storage
module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation

(* Reject any source row whose fields carry qualifiers. Row-writing sinks
   (insert into, create table from a value pipeline) store rows under bare
   names, so a qualified source -- typically the output of a join -- is
   ambiguous: we won't silently drop the qualifier. The error names every
   offending field and points at the [unqualify] operator as the explicit
   strip. [error_prefix] is the already-formatted operator-named prefix
   (e.g. [Insert: into "orders"]) the caller supplies. *)
let reject_qualified_source_for_target ~error_prefix ~source_row_kind =
  let qualified_fields =
    List.filter
      (fun (field : Row.field) -> field.qualifier <> None)
      source_row_kind
  in
  match qualified_fields with
  | [] -> ()
  | _ ->
      let formatted_names =
        List.map
          (fun field -> Printf.sprintf "%S" (Row.format_field_name field))
          qualified_fields
        |> String.concat ", "
      in
      failwith
        (Printf.sprintf
           "%s: source has qualified field(s) %s; pipe through unqualify to \
            drop qualifiers"
           error_prefix formatted_names)

(* For each target field, find the position in [source_row_kind] that supplies
   its value. [Plan.Typecheck]'s [Insert_column_mismatch] check rejects any
   plan whose source is missing a target column, so the missing arm is an
   upstream-invariant violation by the time this helper runs. *)
let build_source_to_target_position_map ~source_row_kind
    ~(target_kind : Relation.kind) =
  List.map
    (fun (target_field : Row.field) ->
      match
        Row.find_field source_row_kind
          { qualifier = None; name = target_field.name }
      with
      | Ok (position, _source_field) -> position
      (* Typecheck has rejected an Insert whose source is missing a target
         column before Eval runs. *)
      | Error _ -> assert false)
    target_kind.row_kind

(* Reorder [source_row] into a row matching [target_kind]'s field order, by
   indexing through [position_map]. The map has one entry per target field, in
   target order, giving the source position for that field's value. *)
let project_to_target_order ~position_map source_row =
  Array.of_list
    (List.map
       (fun source_position -> source_row.(source_position))
       position_map)

(* Extract a human-readable string for the primary-key value of a row already
   projected to [target_kind]'s field order. Used only to build the
   PK-collision error message. *)
let primary_key_value_text (target_kind : Relation.kind) target_row =
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
let write_one_row ~error_prefix ~target_kind ~target_map ~write_transaction
    ~position_map source_row =
  let target_row = project_to_target_order ~position_map source_row in
  let key_bytes, value_bytes =
    Storage.Row_codec.encode_row target_kind target_row
  in
  (match Storage.Engine.get target_map write_transaction ~key:key_bytes with
  | None -> ()
  | Some _ ->
      failwith
        (Printf.sprintf "%s: row with primary key %s already exists"
           error_prefix
           (primary_key_value_text target_kind target_row)));
  Storage.Engine.put target_map write_transaction ~key:key_bytes
    ~value:value_bytes

(* Stream [source_relation]'s rows into [target_table]. Runs the
   qualifier-rejection check on the source, builds the source-to-target
   position map once, then iterates source rows through [write_one_row].
   Returns the number of rows written. [error_prefix] is the already-
   formatted operator-named prefix (e.g. [Insert: into "orders"]) the
   caller supplies; it appears in every user-facing error this helper or
   its callees raise. *)
let write_source_rows_into_table ~error_prefix ~target_kind ~target_map
    ~write_transaction ~(source_relation : _ Relation.t) =
  reject_qualified_source_for_target ~error_prefix
    ~source_row_kind:source_relation.kind.row_kind;
  let position_map =
    build_source_to_target_position_map
      ~source_row_kind:source_relation.kind.row_kind ~target_kind
  in
  (* The row-write is the point of the iteration and the count is
     incidental; [Seq.iter] + [ref] expresses that more honestly than
     folding the count through a [Seq.fold_left] accumulator. *)
  let written_rows = ref 0 in
  Seq.iter
    (fun source_row ->
      write_one_row ~error_prefix ~target_kind ~target_map ~write_transaction
        ~position_map source_row;
      incr written_rows)
    source_relation.value;
  !written_rows
