module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Relation = Dovetail_core.Relation
module Expression = Dovetail_core.Expression

(* Match a column reference against the scanned table's primary-key column.
   A bare reference ([{ qualifier = None; name }]) matches if [name] is the
   PK column's name; a qualified reference ([{ qualifier = Some q; name }])
   matches only when [q] is the scanned table's name. *)
let column_is_primary_key ~table ~primary_key_name
    (reference : Row.column_reference) =
  reference.name = primary_key_name
  &&
  match reference.qualifier with
  | None -> true
  | Some qualifier -> qualifier = table

(* If [kind] has a single-column [Int64] primary key, return the PK column's
   name. Composite keys, missing keys, and non-[Int64] keys all yield [None] --
   the conditions under which IndexLookup folding declines. *)
let single_int64_primary_key (kind : Relation.kind) =
  match Relation.primary_key_names kind with
  | [ primary_key_name ] -> (
      match
        List.find_opt
          (fun (field : Row.field) -> field.name = primary_key_name)
          kind.row_kind
      with
      | Some { kind = Int64; _ } -> Some primary_key_name
      | _ -> None)
  | _ -> None

(* Recognise [predicate] as a PK-equality with an [Int64] literal and pull
   the literal out. Both [pk = K] and [K = pk] match. The column reference
   may be bare or qualified to the scanned table; any other qualifier is a
   non-match. *)
let try_primary_key_equality_literal ~table ~primary_key_name
    (predicate : Expression.t) =
  match predicate with
  | Compare { left = Column reference; op = Equal; right = Literal (Int64 key) }
    when column_is_primary_key ~table ~primary_key_name reference ->
      Some key
  | Compare { left = Literal (Int64 key); op = Equal; right = Column reference }
    when column_is_primary_key ~table ~primary_key_name reference ->
      Some key
  | _ -> None

(* Flatten a conjunction tree into a list of leaf conjuncts, in
   left-to-right order. [And] nodes nest arbitrarily -- both
   [(a And b) And c] and [a And (b And c)] flatten to [[a; b; c]] -- so
   the partitioning step below sees a flat list regardless of how the
   parser associated the [and]s. Non-[And] expressions return as a
   single-element list. *)
let rec flatten_conjunction (expression : Expression.t) =
  match expression with
  | And (left, right) -> flatten_conjunction left @ flatten_conjunction right
  | leaf -> [ leaf ]

(* Walk [conjuncts] in order looking for the first PK-equality with an
   [Int64] literal. If found, return the literal key plus the remaining
   conjuncts (with the matching one removed, order otherwise preserved).
   Two PK-equalities in the same conjunction are handled the simple way:
   the first is folded into the lookup, the rest stay in the residual --
   the runtime [Filter] will then evaluate them against the fetched row,
   which is correct even when the constants disagree. *)
let partition_primary_key_conjunct ~table ~primary_key_name conjuncts =
  let rec walk before = function
    | [] -> None
    | conjunct :: after -> (
        match
          try_primary_key_equality_literal ~table ~primary_key_name conjunct
        with
        | Some key -> Some (key, List.rev_append before after)
        | None -> walk (conjunct :: before) after)
  in
  walk [] conjuncts

(* Fold a non-empty list of conjuncts back into a left-associative [And]
   tree, mirroring how the parser produces left-associative [and] chains.
   Returns [None] for the empty list so the caller can omit the wrapping
   [Filter] when every conjunct has been absorbed into the [IndexLookup]. *)
let build_conjunction = function
  | [] -> None
  | first :: rest ->
      Some
        (List.fold_left
           (fun left right : Expression.t -> And (left, right))
           first rest)

(* Rewrite rule: collapse [Restrict (Scan table, predicate)] into an
   [IndexLookup] (optionally wrapped in a [Filter] carrying the other
   conjuncts) when [predicate] contains an equality between the scanned
   table's [Int64] primary key and a literal. Returns [None] when any
   precondition fails (no catalog entry, composite or non-[Int64] PK, no
   PK-equality conjunct); the caller then falls back to
   [Filter (FullScan ...)]. *)
let rewrite_point_lookup ~catalog ~table ~predicate =
  match catalog table with
  | None -> None
  | Some kind -> (
      match single_int64_primary_key kind with
      | None -> None
      | Some primary_key_name -> (
          let conjuncts = flatten_conjunction predicate in
          match
            partition_primary_key_conjunct ~table ~primary_key_name conjuncts
          with
          | None -> None
          | Some (key, residual_conjuncts) -> (
              let lookup = Physical.IndexLookup { table; key } in
              match build_conjunction residual_conjuncts with
              | None -> Some lookup
              | Some residual ->
                  Some
                    (Physical.Filter { input = lookup; predicate = residual })))
      )

(* If [logical] is a bare [Scan] whose catalog schema has a single-column
   [Int64] primary key, return the table name and the PK column's name.
   Anything else (a sub-plan that isn't a [Scan], an unknown table, a
   composite or non-[Int64] PK) yields [None] and disqualifies the side
   from being an indexed-join inner candidate. *)
let inner_candidate ~catalog (logical : Logical.t) =
  match logical with
  | Scan { table } -> (
      match catalog table with
      | None -> None
      | Some kind -> (
          match single_int64_primary_key kind with
          | None -> None
          | Some primary_key_name -> Some (table, primary_key_name)))
  | _ -> None

(* True if [reference] is qualified to [table] and names [primary_key_name].
   The rewrite requires qualified references: a bare column couldn't be
   reliably attributed to a side of the cross product without resolving
   against a combined schema, and the canonical join queries already
   produce qualified references from the parser. *)
let column_references_table_primary_key ~table ~primary_key_name
    (reference : Row.column_reference) =
  reference.qualifier = Some table && reference.name = primary_key_name

(* Recognise [predicate] as a column-on-column equality where exactly one
   side is the candidate inner's PK column. Returns the *other* column
   reference, which becomes the outer's probe key. Returns [None] when
   neither or both sides match -- "both" rules out a self-join equality
   like [users.id = users.id]. Called once per conjunct by the partition
   walk below, so [predicate] here is always a single conjunct. *)
let try_join_pk_column_equality ~table ~primary_key_name
    (predicate : Expression.t) =
  match predicate with
  | Compare
      {
        left = Column left_reference;
        op = Equal;
        right = Column right_reference;
      } ->
      let left_is_pk =
        column_references_table_primary_key ~table ~primary_key_name
          left_reference
      in
      let right_is_pk =
        column_references_table_primary_key ~table ~primary_key_name
          right_reference
      in
      if left_is_pk && not right_is_pk then Some right_reference
      else if right_is_pk && not left_is_pk then Some left_reference
      else None
  | _ -> None

(* Everything the indexed-join rewrite needs in order to emit the operator:
   the chosen outer's logical sub-plan, the inner table, the outer's probe
   column, the inner's position in the original [CrossProduct], and the
   conjuncts left over after the equality has been absorbed. *)
type indexed_join_match = {
  outer_logical : Logical.t;
  inner_table : string;
  outer_key_column : Row.column_reference;
  inner_position : [ `Left | `Right ];
  residual_conjuncts : Expression.t list;
}

(* Match a single conjunct against the left/right candidates, applying
   the "both sides of the equality match" tiebreaker (prefer right as
   inner). Returns the chosen outer's logical sub-plan, the inner
   table, the outer's probe column, and the inner's logical position --
   the match-without-residual that the partition walker assembles into
   the full [indexed_join_match] record. *)
let try_match_conjunct ~left ~right ~left_candidate ~right_candidate conjunct =
  let try_candidate candidate =
    match candidate with
    | None -> None
    | Some (table, primary_key_name) -> (
        match try_join_pk_column_equality ~table ~primary_key_name conjunct with
        | Some outer_key_column -> Some (table, outer_key_column)
        | None -> None)
  in
  match (try_candidate left_candidate, try_candidate right_candidate) with
  | Some _, Some (table, outer_key_column) ->
      Some (left, table, outer_key_column, `Right)
  | Some (table, outer_key_column), None ->
      Some (right, table, outer_key_column, `Left)
  | None, Some (table, outer_key_column) ->
      Some (left, table, outer_key_column, `Right)
  | None, None -> None

(* Walk [conjuncts] left-to-right; the first conjunct that matches a
   candidate's PK is folded into the indexed join, with the remaining
   conjuncts becoming the residual (order otherwise preserved). Sibling
   to [partition_primary_key_conjunct] -- the structure is identical;
   only the per-conjunct match predicate differs. *)
let partition_join_pk_conjunct ~left ~right ~left_candidate ~right_candidate
    conjuncts =
  let rec walk before = function
    | [] -> None
    | conjunct :: after -> (
        match
          try_match_conjunct ~left ~right ~left_candidate ~right_candidate
            conjunct
        with
        | Some (outer_logical, inner_table, outer_key_column, inner_position) ->
            Some
              {
                outer_logical;
                inner_table;
                outer_key_column;
                inner_position;
                residual_conjuncts = List.rev_append before after;
              }
        | None -> walk (conjunct :: before) after)
  in
  walk [] conjuncts

(* Rewrite rule: collapse [Restrict (CrossProduct(left, right), predicate)]
   into an [IndexedNestedLoopJoin] (optionally wrapped in a [Filter] for
   the residual conjuncts) when one side is a [Scan] of a table with a
   single-column [Int64] PK and [predicate] contains a column-on-column
   equality naming that PK. Returns [None] when no such match is found;
   the caller then falls back to [NestedLoopJoin] with the original
   predicate.

   Two layered choices when more than one shape qualifies: across
   conjuncts, left-to-right order wins; within a single conjunct that
   names both candidates' PKs (e.g. [a.id = b.id] with both having PK
   [id]), the tiebreaker prefers the right side as the inner so the
   outer side preserves the logical [CrossProduct]'s column order. *)
let rewrite_indexed_nested_loop_join ~translate_outer ~catalog ~left ~right
    ~predicate =
  let left_candidate = inner_candidate ~catalog left in
  let right_candidate = inner_candidate ~catalog right in
  let conjuncts = flatten_conjunction predicate in
  match
    partition_join_pk_conjunct ~left ~right ~left_candidate ~right_candidate
      conjuncts
  with
  | None -> None
  | Some
      {
        outer_logical;
        inner_table;
        outer_key_column;
        inner_position;
        residual_conjuncts;
      } -> (
      let join =
        Physical.IndexedNestedLoopJoin
          {
            outer = translate_outer outer_logical;
            inner_table;
            outer_key_column;
            inner_position;
          }
      in
      match build_conjunction residual_conjuncts with
      | None -> Some join
      | Some residual ->
          Some (Physical.Filter { input = join; predicate = residual }))

(* Compare two string lists as multisets: returns the names present in
   [expected] but not in [actual] and the names present in [actual] but not
   in [expected]. Used by the literal/schema permutation check; the
   non-overlapping difference is exactly the actionable error wording
   ("missing columns: x, y" / "unknown columns: z"). *)
let multiset_difference ~expected ~actual =
  let missing = List.filter (fun name -> not (List.mem name actual)) expected in
  let unknown = List.filter (fun name -> not (List.mem name expected)) actual in
  (missing, unknown)

(* Check that [literal_kind]'s field names are a permutation of
   [target_kind]'s. Raises [Failure] naming the missing columns first, then
   the unknown ones -- a single literal can hit both, and the missing-
   columns message is the more directly actionable of the two. *)
let check_columns_match ~target_table ~(target_kind : Relation.kind)
    ~(literal_kind : Relation.kind) =
  let target_column_names =
    List.map (fun (field : Row.field) -> field.name) target_kind.row_kind
  in
  let literal_column_names =
    List.map (fun (field : Row.field) -> field.name) literal_kind.row_kind
  in
  let missing, unknown =
    multiset_difference ~expected:target_column_names
      ~actual:literal_column_names
  in
  if missing <> [] then
    failwith
      (Printf.sprintf "Translate: insert into %S: missing column(s): %s"
         target_table
         (String.concat ", " missing));
  if unknown <> [] then
    failwith
      (Printf.sprintf "Translate: insert into %S: unknown column(s): %s"
         target_table
         (String.concat ", " unknown))

(* Check that each field in [literal_kind] has the same scalar kind as the
   target column with the same name. Raises [Failure] naming the column and
   both kinds.

   Precondition: [check_columns_match] has passed, so every name in
   [literal_kind] resolves in [target_kind.row_kind]. *)
let check_value_kinds ~target_table ~(target_kind : Relation.kind)
    ~(literal_kind : Relation.kind) =
  List.iter
    (fun (literal_field : Row.field) ->
      let target_field =
        List.find
          (fun (field : Row.field) -> field.name = literal_field.name)
          target_kind.row_kind
      in
      if literal_field.kind <> target_field.kind then
        failwith
          (Printf.sprintf
             "Translate: insert into %S: column %S expects %s, got %s"
             target_table literal_field.name
             (Scalar.kind_to_string target_field.kind)
             (Scalar.kind_to_string literal_field.kind)))
    literal_kind.row_kind

(* Run the literal/target checks in order: column-set agreement, then
   per-column kinds. Each helper raises [Failure] on its own contract; this
   orchestrator just sequences them. *)
let validate_literal_against_target ~target_table ~target_kind ~literal_kind =
  check_columns_match ~target_table ~target_kind ~literal_kind;
  check_value_kinds ~target_table ~target_kind ~literal_kind

(* Run validation when the insert source is a [Relation_literal]; pass through
   silently for any other source. Non-literal sources aren't a tested path
   yet, but the sink stays source-agnostic by design -- the sink itself
   enforces column coverage at eval time. *)
let validate_mutation_source ~target_table ~target_kind (source : Logical.t) =
  match source with
  | Relation_literal { kind = literal_kind; _ } ->
      validate_literal_against_target ~target_table ~target_kind ~literal_kind
  | _ -> ()

let rec translate_relation ~catalog (plan : Logical.t) : Physical.t =
  match plan with
  | Scan { table } -> FullScan { table }
  (* Inner-join rewrite: must precede the general [Restrict] case below.
     Try the indexed strategy first; fall through to [NestedLoopJoin]
     when no side has a PK-equality match against the predicate. *)
  | Restrict { input = CrossProduct { left; right }; predicate } -> (
      match
        rewrite_indexed_nested_loop_join
          ~translate_outer:(translate_relation ~catalog)
          ~catalog ~left ~right ~predicate
      with
      | Some plan -> plan
      | None ->
          NestedLoopJoin
            {
              left = translate_relation ~catalog left;
              right = translate_relation ~catalog right;
              predicate;
            })
  (* PK point-lookup rewrite: fires when [predicate] is a bare equality
     between the scanned table's PK column and an [Int64] literal. Falls
     through to the general [Filter (FullScan ...)] form when the catalog
     doesn't recognise the table, the PK isn't a single [Int64] column, or
     the predicate isn't shaped right. *)
  | Restrict { input = Scan { table }; predicate } -> (
      match rewrite_point_lookup ~catalog ~table ~predicate with
      | Some plan -> plan
      | None -> Filter { input = FullScan { table }; predicate })
  | Restrict { input; predicate } ->
      Filter { input = translate_relation ~catalog input; predicate }
  | Project { input; columns } ->
      Project { input = translate_relation ~catalog input; columns }
  | CrossProduct { left; right } ->
      CrossProduct
        {
          left = translate_relation ~catalog left;
          right = translate_relation ~catalog right;
        }
  | Relation_literal { kind; rows } -> Relation_literal { kind; rows }
  | Insert { table; source } -> translate_insert ~catalog ~table ~source
  | Unqualify { input } ->
      Unqualify { input = translate_relation ~catalog input }
  | Type_op { input } -> Type_op { input = translate_relation ~catalog input }
  | Scalar_literal value -> Scalar_literal value
  | Row_literal { fields } -> Row_literal { fields }
  | Drop_table { table_name } -> Drop_table { table_name }
  | Create_table_empty { table_name; kind } ->
      Create_table_empty { table_name; kind }
  | Create_table_seeded { table_name; source } ->
      Create_table_seeded
        { table_name; source = translate_relation ~catalog source }

(* Look up [target_table]'s kind in the catalog and validate the literal
   source's columns and value kinds against it. Returns the translated
   physical [Insert]. Raises [Failure] if the catalog has no kind for the
   table or any validation check fails. *)
and translate_insert ~catalog ~table ~source : Physical.t =
  let target_kind =
    match catalog table with
    | Some kind -> kind
    | None ->
        failwith
          (Printf.sprintf "Translate: insert into %S: unknown table" table)
  in
  validate_mutation_source ~target_table:table ~target_kind source;
  Insert { table; source = translate_relation ~catalog source }

let translate = translate_relation
