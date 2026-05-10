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
