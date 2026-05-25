(** Physical relational-algebra IR.

    The physical IR is what {!Eval} executes. Each constructor maps to a
    concrete execution strategy: storage cursors, nested-loop joins, index
    lookups, and so on. The earlier IRs ({!Logical}, {!Ast}) are progressively
    translated down into this one. *)

module Scalar = Dovetail_core.Scalar
module Row = Dovetail_core.Row
module Expression = Dovetail_core.Expression
module Relation = Dovetail_core.Relation

type t =
  | FullScan of { table : string }
      (** [FullScan { table }] reads every row of [table] in primary-key order
          via a cursor over the table's storage subDB. *)
  | Filter of { input : t; predicate : Expression.t }
      (** [Filter { input; predicate }] yields the rows from [input] for which
          [predicate] holds. Kind and multiplicity tag are passed through from
          [input] -- filtering preserves whether the input is a set or a bag. *)
  | Project of { input : t; columns : Projection.t }
      (** [Project { input; columns }] yields the rows from [input] narrowed to
          the named [columns], in the order given. The output schema's
          [primary_key] is always empty -- derived relations don't carry PK
          information at this point in the project. The multiplicity tag
          downgrades to [`Bag] because dropping columns can introduce duplicates
          that weren't present in the input. *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] yields every (left, right) row pair,
          executed as a nested loop with the right side materialised once. The
          result schema is [left]'s fields followed by [right]'s, with
          qualifiers preserved; the [primary_key] is empty. Cross product
          preserves the multiplicity tag, since pairing two rows can only
          duplicate values that the inputs already had. The dedicated [Join]
          operator with multiple strategies (hash, merge) is a future addition.
      *)
  | IndexLookup of { table : string; key : int64 }
      (** [IndexLookup { table; key }] fetches the single row in [table] whose
          primary key equals [key], by encoding [key] and calling
          [Storage.Engine.get] on the table's storage subDB. The result is a
          relation with the table's full schema and either zero or one rows.
          Always cheaper than a [FullScan] when the predicate fixes the primary
          key.

          The [key] field is [int64] for now: every primary key in dovetail is a
          single [int64] column at this point. The field widens to
          [Scalar.value] when other key kinds arrive. *)
  | NestedLoopJoin of { left : t; right : t; predicate : Expression.t }
      (** [NestedLoopJoin { left; right; predicate }] yields every (left, right)
          row pair for which [predicate] holds, executed as a nested loop with
          the right side materialised once and the predicate fused into the
          inner loop. Kind construction matches [CrossProduct]: [left]'s fields
          followed by [right]'s, qualifiers preserved, [primary_key] empty. The
          multiplicity tag is preserved -- the join cannot introduce duplicates
          that weren't already implicit in the cross.

          Per-pair work is the same as [Filter (CrossProduct ...)]; the node
          exists so that {!Translate} has a place to emit when it recognises an
          inner join, and so future strategies (indexed nested-loop, hash join,
          merge join) have siblings to slot in next to. *)
  | IndexedNestedLoopJoin of {
      outer : t;
      inner_table : string;
      outer_key_column : Row.column_reference;
      inner_position : [ `Left | `Right ];
    }
      (** [IndexedNestedLoopJoin { outer; inner_table; outer_key_column;
           inner_position }] streams [outer] and probes [inner_table]'s storage
          subDB once per outer row by the value at [outer_key_column], joining
          on the inner's primary key. Per-row cost is O(log |inner|) rather than
          the O(|inner|) of a plain nested-loop join.

          [outer_key_column] names a column in [outer]'s schema; its per-row
          value is encoded with [Storage.Encoding.encode_int64_key] and used as
          the probe key. Its kind must be [Int64] -- the inner's PK kind --
          checked at eval time. An outer row whose probe misses is dropped.

          [inner_position] records where the inner sat in the original logical
          [CrossProduct]: [`Left] produces [inner.fields @ outer.fields],
          [`Right] produces [outer.fields @ inner.fields]. The tag exists so the
          indexed rewrite doesn't silently reorder a query's output columns when
          the optimisation flips outer and inner -- optimisations are observable
          in the plan and in performance, not in the result shape.

          The output [primary_key] is [], matching [NestedLoopJoin] and
          [CrossProduct]. *)
  | Relation_literal of { kind : Relation.kind; rows : Scalar.value list list }
      (** [Relation_literal { kind; rows }] yields a relation whose row kind is
          declared up front. Each row in [rows] is a list of values in the order
          of [kind.row_kind]'s fields. The empty form ([rows = []]) is valid
          because the kind is declared directly, not inferred from a first row.
          {!Eval} uses [kind] directly. *)
  | Insert of { table : string; source : t }
      (** [Insert { table; source }] writes [source]'s rows to [table] and
          yields a one-row relation reporting the affected-row count. {!Eval}
          handles it as a regular case, writing rows inside the active write
          transaction and producing the (insert_count : int64) result. *)
  | Unqualify of { input : t }
      (** [Unqualify { input }] strips the qualifier from every field of
          [input]'s row kind. {!Eval} runs the input, builds a new kind by
          setting every field's qualifier to [None], and emits the input's rows
          unchanged under the new kind. Accepts either a relation
          ({!Term.Relation_value}) or a row ({!Term.Row_value}) on the input.
          Raises [Failure] if two fields collide on their bare name after
          stripping; {!kind_of} raises the same way. *)
  | Type_op of { input : t }
      (** [Type_op { input }] yields [input]'s relation kind rather than its
          rows. {!Eval} reads the static kind via {!kind_of} without opening any
          cursors. The node sits at the root of a plan only; {!kind_of} raises
          [Failure] if called on a [Type_op] directly, since the operator's
          evaluation result is a kind, not a relation. *)
  | Scalar_literal of Scalar.value
      (** [Scalar_literal value] yields the literal [value] directly — no
          storage, no cursors. {!Eval} hands it down the pipe as a
          {!Term.Scalar_value}. Sits at a plan's root only; {!kind_of} raises
          [Failure] because the operator's result is a scalar value, not a
          relation. The [Type_op] evaluator handles a [Scalar_literal] input
          specially, computing the corresponding {!Scalar.kind} directly. *)
  | Drop_table of { table_name : string }
      (** [Drop_table { table_name }] removes [table_name] from the catalog and
          deletes its storage subDB, all in the active write transaction.
          {!kind_of} reports a one-row [(dropped : string)] result. *)
  | Create_table_empty of { table_name : string; kind : Relation.kind }
      (** [Create_table_empty { table_name; kind }] creates an empty table named
          [table_name] with the declared [kind]: registers the kind in the
          catalog and provisions its storage subDB, in the active write
          transaction. {!kind_of} reports a one-row [(created : string)] result.
      *)
  | Create_table_seeded of { table_name : string; source : t }
      (** [Create_table_seeded { table_name; source }] creates [table_name] from
          [source]'s row kind and seeds it with [source]'s rows, all in the
          active write transaction. The target kind is derived from [source]'s
          kind at eval time (the evaluator calls {!kind_of} on [source], rejects
          a qualified source, stamps each field with [Some table_name], and
          requires a primary key). {!kind_of} on the node reports a one-row
          [(created : string)] result -- the source kind is not the node's
          result kind. *)
  | Row_literal of { fields : (Row.column_reference * Scalar.value) list }
      (** [Row_literal { fields }] yields the literal row directly — no storage,
          no cursors. Each entry pairs a column reference (qualified
          [qualifier.name] or bare [name]) with its value. {!Eval} assembles a
          {!Row.t} from [fields] and hands it down the pipe as a
          {!Term.Row_value}; the row's field kinds come from the values' scalar
          kinds, and the qualifiers come from the references. Sits at a plan's
          root only; {!kind_of} raises [Failure] because the operator's result
          is a row value, not a relation. The [Type_op] evaluator handles a
          [Row_literal] input specially, computing the corresponding {!Row.kind}
          directly. *)

val kind_of : catalog:(string -> Relation.kind option) -> t -> Relation.kind
(** [kind_of ~catalog plan] returns [plan]'s result kind — the {!Relation.kind}
    {!Eval} would hand its continuation, without opening any cursors or pulling
    any rows.

    [catalog] supplies the kind for the [FullScan] / [IndexLookup] /
    [IndexedNestedLoopJoin] cases that reference a stored table; the other
    operators compute their kind from their inputs alone. Raises [Failure] when
    [catalog] has no kind for a referenced table.

    Used by the [type] operator's evaluator to report the type of its input
    without materialising the input. *)

val format : Format.formatter -> t -> unit
(** [format formatter plan] writes [plan] to [formatter] as an indented tree,
    one operator per line, with each operator's inputs indented two spaces
    further than the operator itself. Every operator renders its name followed
    by its distinguishing parameters inside parentheses ([FullScan(table)],
    [Filter(predicate)], [Project(columns)], [IndexLookup(table, key=KEY)],
    [NestedLoopJoin(predicate)],
    [IndexedNestedLoopJoin(inner=..., outer_key=..., inner_position=...)],
    [RelationLiteral(columns=..., rows=N)], [Insert(table)]). [CrossProduct] is
    the only operator that renders bare, because its two children are themselves
    the interesting information. The output is for EXPLAIN-style debug printing
    -- the [--show-physical] flag on the binary is the primary consumer. *)
