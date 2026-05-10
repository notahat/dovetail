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
  | Filter of { input : t; predicate : Predicate.t }
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
