(* Match a column reference against the scanned table's primary-key column.
   A bare reference ([{ qualifier = None; name }]) matches if [name] is the
   PK column's name; a qualified reference ([{ qualifier = Some q; name }])
   matches only when [q] is the scanned table's name. *)
let column_is_primary_key ~table ~primary_key_name
    (reference : Schema.column_reference) =
  reference.name = primary_key_name
  &&
  match reference.qualifier with
  | None -> true
  | Some qualifier -> qualifier = table

(* If [schema] has a single-column [Int64] primary key, return the PK column's
   name. Composite keys, missing keys, and non-[Int64] keys all yield [None] --
   the conditions under which slice 8 declines to fold. *)
let single_int64_primary_key (schema : Schema.t) =
  match schema.primary_key with
  | [ primary_key_name ] -> (
      match
        List.find_opt
          (fun (field : Schema.field) -> field.name = primary_key_name)
          schema.fields
      with
      | Some { kind = Int64; _ } -> Some primary_key_name
      | _ -> None)
  | _ -> None

(* Recognise [predicate] as a PK-equality with an [Int64] literal and pull
   the literal out. Both [pk = K] and [K = pk] match. The column reference
   may be bare or qualified to the scanned table; any other qualifier is a
   non-match. Step 2 only handles the bare [Compare] shape -- conjunction
   walking arrives in step 3. *)
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

(* Try to rewrite [Restrict (Scan table, predicate)] as an [IndexLookup],
   possibly wrapped in a [Filter] carrying the predicate's other conjuncts.
   Returns [None] when any precondition fails (no catalog entry, composite
   or non-[Int64] PK, no PK-equality conjunct), in which case the caller
   falls back to [Filter (FullScan ...)]. *)
let try_index_lookup ~catalog ~table ~predicate =
  match catalog table with
  | None -> None
  | Some schema -> (
      match single_int64_primary_key schema with
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

let rec translate ~catalog (plan : Logical.t) : Physical.t =
  match plan with
  | Scan { table } -> FullScan { table }
  (* Inner-join rewrite: must precede the general [Restrict] case below. *)
  | Restrict { input = CrossProduct { left; right }; predicate } ->
      NestedLoopJoin
        {
          left = translate ~catalog left;
          right = translate ~catalog right;
          predicate;
        }
  (* PK point-lookup rewrite: fires when [predicate] is a bare equality
     between the scanned table's PK column and an [Int64] literal. Falls
     through to the general [Filter (FullScan ...)] form when the catalog
     doesn't recognise the table, the PK isn't a single [Int64] column, or
     the predicate isn't shaped right. *)
  | Restrict { input = Scan { table }; predicate } -> (
      match try_index_lookup ~catalog ~table ~predicate with
      | Some plan -> plan
      | None -> Filter { input = FullScan { table }; predicate })
  | Restrict { input; predicate } ->
      Filter { input = translate ~catalog input; predicate }
  | Project { input; columns } ->
      Project { input = translate ~catalog input; columns }
  | CrossProduct { left; right } ->
      CrossProduct
        { left = translate ~catalog left; right = translate ~catalog right }
