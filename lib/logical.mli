(** Logical relational-algebra IR.

    The logical IR is the layer between the surface AST and the physical
    operators that {!Eval} executes. Logical operators describe *what* a query
    computes — read these rows, keep these columns, join on this predicate —
    without committing to *how*. {!Translate} lowers logical operators into a
    physical plan that picks an execution strategy.

    Slice 1 introduced [Scan]; slice 2 adds [Restrict] (the σ of relational
    algebra; "restrict" rather than "select" to avoid future collision with
    SQL's SELECT, which will eventually live in another front end). Further
    logical operators arrive as later slices introduce them. *)

type t =
  | Scan of { table : string }
      (** [Scan { table }] reads every row of [table]. The logical operator
          carries no execution detail; it's the [Translate] layer's job to pick
          between full-scan, index-scan, and so on. *)
  | Restrict of { input : t; predicate : Predicate.t }
      (** [Restrict { input; predicate }] keeps the rows of [input] for which
          [predicate] holds. The constructor name follows the relational-algebra
          term for σ; the executor convention (Filter) takes over once
          {!Translate} has run. *)
  | Project of { input : t; columns : Projection.t }
      (** [Project { input; columns }] narrows [input] to the named [columns],
          in the order given. Mirrors π in the relational algebra. The output
          schema's [primary_key] is empty regardless of whether [columns]
          includes the input's PK; see {!Projection.resolve}. *)
  | CrossProduct of { left : t; right : t }
      (** [CrossProduct { left; right }] is the cartesian product (×) of the two
          inputs: every (left, right) tuple pair. The result schema is [left]'s
          fields followed by [right]'s, with qualifiers preserved. The output
          [primary_key] is empty: derived relations don't carry PK information
          at this point in the project. *)
