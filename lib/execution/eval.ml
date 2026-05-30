module Term = Dovetail_core.Term
module Storage = Dovetail_storage
module Plan = Dovetail_plan

(* CPS-shaped executor. Every operator is in continuation-passing form so
   the consumer's [continue] runs inside whatever cursor and resource
   scopes the plan opens, letting rows stream directly from live
   cursors rather than being eagerly materialised. *)
let rec eval environment transaction plan continue =
  match (plan : Plan.Physical.t) with
  | Catalog_source ->
      Eval_catalog_source.evaluate environment transaction continue
  | Create_table_empty { table_name; kind } ->
      Eval_create_table_empty.evaluate environment transaction ~table_name ~kind
        continue
  | Create_table_seeded { table_name; source } ->
      Eval_create_table_seeded.evaluate ~eval_relation environment transaction
        ~table_name ~source continue
  | CrossProduct { left; right } ->
      Eval_cross_product.evaluate ~eval_relation environment transaction ~left
        ~right continue
  | Drop_table { table_name } ->
      Eval_drop_table.evaluate environment transaction ~table_name continue
  | Filter { input; predicate } ->
      Eval_filter.evaluate ~eval_relation environment transaction ~input
        ~predicate continue
  | FullScan { table } ->
      Eval_full_scan.evaluate environment transaction table continue
  | IndexedNestedLoopJoin
      { outer; inner_table; outer_key_column; inner_position } ->
      Eval_indexed_nested_loop_join.evaluate ~eval_relation environment
        transaction ~outer ~inner_table ~outer_key_column ~inner_position
        continue
  | IndexLookup { table; key } ->
      Eval_index_lookup.evaluate environment transaction ~table ~key continue
  | Insert { table; source } ->
      Eval_insert.evaluate ~eval_relation environment transaction
        ~target_table:table ~source continue
  | NestedLoopJoin { left; right; predicate } ->
      Eval_nested_loop_join.evaluate ~eval_relation environment transaction
        ~left ~right ~predicate continue
  | Project { input; columns } ->
      Eval_project.evaluate ~eval_relation environment transaction ~input
        ~columns continue
  | Relation_literal { kind; rows } ->
      Eval_relation_literal.evaluate ~kind ~rows continue
  | Row_literal { fields } -> Eval_row_literal.evaluate fields continue
  | Scalar_literal value -> continue (Term.Scalar_value value)
  | Tables { input } ->
      Eval_tables.evaluate ~eval environment transaction ~input continue
  | Type_op { input } ->
      Eval_type_op.evaluate environment transaction ~input continue
  | Unqualify { input } ->
      Eval_unqualify.evaluate ~eval environment transaction ~input continue

(* CPS helper for internal recursion: a relational operator's sub-plan always
   produces a [Term.Relation_value]. The [Term.Relation_kind] arm only arises
   from the [Type_op] operator, which sits at the pipeline root and is never
   the input of another relational operator. *)
and eval_relation environment transaction plan continue =
  eval environment transaction plan (function
    | Term.Relation_value relation -> continue relation
    | Term.Relation_kind _ | Term.Scalar_value _ | Term.Scalar_kind _
    | Term.Row_value _ | Term.Row_kind _ | Term.Catalog_value _
    | Term.Catalog_kind _ ->
        (* By construction relational sub-plans only ever produce relation
           values. Kinds arise from [Type_op]; the scalar, row, and catalog
           arms have no constructors that wire into a relational sub-plan
           today. *)
        assert false)
