(** Physical relational-algebra IR.

    The physical IR is what {!Eval} executes. Each constructor maps to a
    concrete execution strategy: storage cursors, nested-loop joins, index
    lookups, and so on. The earlier IRs ({!Logical}, {!Ast}) are progressively
    translated down into this one. *)

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
  | IndexedNestedLoopJoin of {
      outer : t;
      inner_table : string;
      outer_key_column : Schema.column_reference;
      inner_position : [ `Left | `Right ];
    }
      (** [IndexedNestedLoopJoin { outer; inner_table; outer_key_column;
           inner_position }] streams [outer] and probes [inner_table]'s storage
          subDB once per outer tuple by the value at [outer_key_column], joining
          on the inner's primary key. Per-row cost is O(log |inner|) rather than
          the O(|inner|) of a plain nested-loop join.

          [outer_key_column] names a column in [outer]'s schema; its per-row
          value is encoded with [Encoding.encode_int64_key] and used as the
          probe key. Its kind must be [Int64] -- the inner's PK kind -- checked
          at eval time. An outer tuple whose probe misses is dropped.

          [inner_position] records where the inner sat in the original logical
          [CrossProduct]: [`Left] produces [inner.fields @ outer.fields],
          [`Right] produces [outer.fields @ inner.fields]. The tag exists so the
          indexed rewrite doesn't silently reorder a query's output columns when
          the optimisation flips outer and inner -- optimisations are observable
          in the plan and in performance, not in the result shape.

          The output [primary_key] is [], matching [NestedLoopJoin] and
          [CrossProduct]. *)
  | RelationLiteral of { columns : string list; rows : Value.t list list }
      (** [RelationLiteral { columns; rows }] yields a relation whose tuples are
          the literal's [rows] -- no storage involved. The output schema names
          the columns in order with no qualifier; each field's kind is inferred
          from the first row's value at that position; the primary key is empty,
          matching the convention for derived relations.

          Each row in [rows] must have the same length as [columns]. Slice 11's
          parser produces single-row literals only, so [rows] always has length
          one in user-driven plans; the IR shape leaves room for a future
          multi-row literal grammar. *)

type mutation =
  | Insert of { table : string; source : t }
      (** A mutation produces no relation -- only a count of affected rows.
          {!Eval.eval_mutation} is the executor entry. The [source] field is a
          relation-yielding sub-plan: its rows are what get written.

          The {!plan} wrapper below sits above this type so the REPL can
          dispatch on plan kind between {!Eval.eval} (for queries) and
          {!Eval.eval_mutation} (for mutations). The constructor is part of the
          slice 11 DML surface; further mutations (update, delete) land
          additively in slice 12. *)

type plan =
  | Query of t
  | Mutation of mutation
      (** A top-level physical plan: either a relation-yielding {!t} or a
          row-writing {!mutation}. {!Translate.translate} returns this, and the
          REPL dispatches on it to pick a transaction kind and the right {!Eval}
          entry point. Mutations don't nest, because the wrapper's {!Mutation}
          constructor only appears at the top: [Insert]'s [source] is a {!t},
          not a [plan]. *)

val format : Format.formatter -> t -> unit
(** [format formatter plan] writes [plan] to [formatter] as an indented tree,
    one operator per line, with each operator's inputs indented two spaces
    further than the operator itself. Every operator renders its name followed
    by its distinguishing parameters inside parentheses ([FullScan(table)],
    [Filter(predicate)], [Project(columns)], [IndexLookup(table, key=KEY)],
    [NestedLoopJoin(predicate)],
    [IndexedNestedLoopJoin(inner=..., outer_key=..., inner_position=...)],
    [RelationLiteral(columns=..., rows=N)]). [CrossProduct] is the only operator
    that renders bare, because its two children are themselves the interesting
    information. The output is for EXPLAIN-style debug printing -- the
    [--show-physical] flag on the binary is the primary consumer. *)

val format_plan : Format.formatter -> plan -> unit
(** [format_plan formatter plan] writes [plan] to [formatter]. For a {!Query},
    the inner relation tree renders exactly as {!format} would render it -- no
    wrapping header. For a {!Mutation}, the mutation prints its operator header
    ([Insert(table)]) on one line with the [source] indented one level beneath,
    matching the per-operator indentation convention {!format} uses. *)
