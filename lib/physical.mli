(** Physical relational-algebra IR.

    The physical IR is what {!Eval} executes. Each constructor maps to a
    concrete execution strategy: storage cursors, hash joins, sort-merge joins,
    and so on. The earlier IRs ({!Logical}, {!Ast}) are progressively translated
    down into this one.

    Slice 1 introduced [FullScan]; slice 2 adds [Filter]. Further operators
    arrive as later slices introduce them. *)

type t =
  | FullScan of { table : string }
      (** [FullScan { table }] reads every row of [table] in primary-key order
          via a cursor over the table's storage subDB. *)
  | Filter of { input : t; predicate : Expression.t }
      (** [Filter { input; predicate }] yields the rows from [input] for which
          [predicate] holds. Schema and multiplicity tag are passed through from
          [input] -- filtering preserves whether the input is a set or a bag. *)
  | Project of { input : t; columns : Projection.t }
      (** [Project { input; columns }] yields the rows from [input] narrowed to
          the named [columns], in the order given. The output schema's
          [primary_key] is always empty -- derived relations don't carry PK
          information at this point in the project. The multiplicity tag
          downgrades to [`Bag] because dropping columns can introduce duplicates
          that weren't present in the input. *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] yields every (left, right) tuple pair,
          executed as a nested loop with the right side materialised once. The
          result schema is [left]'s fields followed by [right]'s, with
          qualifiers preserved; the [primary_key] is empty. Cross product
          preserves the multiplicity tag, since pairing two rows can only
          duplicate values that the inputs already had. The dedicated [Join]
          operator (with multiple strategies on the roadmap -- hash, merge)
          ships in a later slice. *)
  | IndexLookup of { table : string; key : int64 }
      (** [IndexLookup { table; key }] fetches the single row in [table] whose
          primary key equals [key], by encoding [key] and calling [Storage.get]
          on the table's storage subDB. The result is a relation with the
          table's full schema and either zero or one tuples. Always cheaper than
          a [FullScan] when the predicate fixes the primary key.

          The [key] field is [int64] for now: every primary key in dovetail is a
          single [int64] column at this point. The field widens to [Value.t]
          when other key kinds arrive. *)
  | NestedLoopJoin of { left : t; right : t; predicate : Expression.t }
      (** [NestedLoopJoin { left; right; predicate }] yields every (left, right)
          tuple pair for which [predicate] holds, executed as a nested loop with
          the right side materialised once and the predicate fused into the
          inner loop. Schema construction matches [CrossProduct]: [left]'s
          fields followed by [right]'s, qualifiers preserved, [primary_key]
          empty. The multiplicity tag is preserved -- the join cannot introduce
          duplicates that weren't already implicit in the cross.

          Per-pair work is the same as [Filter (CrossProduct ...)]; the node
          exists so that {!Translate} has a place to emit when it recognises an
          inner join, and so future strategies (indexed nested-loop, hash join,
          merge join) have siblings to slot in next to. *)

val format : Format.formatter -> t -> unit
(** [format formatter plan] writes [plan] to [formatter] as an indented tree,
    one operator per line, with each operator's inputs indented two spaces
    further than the operator itself. The leaf operator [FullScan] renders as
    [FullScan(table)]; operators that carry a parameter render it inside
    parentheses on the operator's line ([Filter(predicate)], [Project(columns)],
    [NestedLoopJoin(predicate)]). The output is for EXPLAIN-style debug printing
    -- the [--show-physical] flag on the binary is the primary consumer. *)
