(** Lower the SQL surface AST into the shared logical relational-algebra IR.

    {!Lower.lower} maps a {!Ast.t} onto a {!Dovetail_plan.Logical.t}. The SQL
    surface and the relational-algebra surface lower to the *same* logical IR;
    this is where SQL's vocabulary ([SELECT] / [FROM]) is translated into the
    algebraic operators ([Scan] / [Restrict] / [Project]).

    [SELECT *] is the identity over its FROM/WHERE sub-plan -- it lowers with no
    [Project] node, preserving the input's primary key and set/bag tag, exactly
    as a relational-algebra pipeline that omits its [project] step does. A
    [WHERE] predicate lowers to a [Restrict] wrapping the [Scan]; the predicate
    maps onto the shared {!Dovetail_core.Expression.t} (both [<>] and [!=]
    having already been collapsed to [NotEqual] by the parser). A column-list
    select lowers to a [Project] over that FROM/WHERE sub-plan, keeping the
    columns in the order written. *)

module Plan = Dovetail_plan

val lower : Ast.t -> Plan.Logical.t
(** [lower ast] lowers a parsed SQL statement to a logical plan.
    [SELECT * FROM <table>] lowers to [Scan { table }]; a [WHERE <predicate>]
    wraps that scan in [Restrict { input = Scan; predicate }]; a column-list
    select wraps the result in [Project { input; columns }], preserving column
    order. The predicate's kind discipline (it must resolve to [Bool]) and the
    projected columns' existence are enforced later, by {!Plan.Typecheck},
    exactly as for the relational-algebra surface. *)
