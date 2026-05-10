(** Physical relational-algebra IR.

    The physical IR is what {!Eval} executes. Each constructor maps to a
    concrete execution strategy: storage cursors, hash joins, sort-merge joins,
    and so on. The earlier IRs ({!Logical}, {!Ast}) are progressively translated
    down into this one.

    Slice 1 ships only [FullScan]; further operators arrive as later slices
    introduce them. *)

type t =
  | FullScan of { table : string }
      (** [FullScan { table }] reads every row of [table] in primary-key order
          via a cursor over the table's storage subDB. *)
