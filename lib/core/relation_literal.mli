(** The kind-inference rule for the [RelationLiteral] IR constructor.

    [RelationLiteral { columns; rows }] appears unchanged in {!Ast}, {!Logical},
    and {!Physical}; the rule for deriving a {!Relation.kind} from one is the
    same at every layer and lives here so the IR doc comments can point at a
    single definition rather than each restating the wording. *)

val kind_of : columns:string list -> first_row:Value.data list -> Relation.kind
(** [kind_of ~columns ~first_row] builds the {!Relation.kind} implied by a
    relation literal. Field names come from [columns] in order; each field's
    [Value.kind] is inferred from the value at the same position in [first_row];
    every field has [qualifier = None]; the kind carries no refinements,
    matching the convention for derived relations.

    Inferring kinds from only the first row is sufficient because the literal
    grammar is currently single-row. Multi-row literals will need to verify the
    later rows agree with the first; that check belongs upstream of this helper,
    which sees only one row.

    @raise Invalid_argument
      if [first_row] and [columns] differ in length. Callers that surface this
      error to users (the parser, [Translate]'s mutation arm) check lengths
      first and produce a user-facing [Failure] before reaching here; the
      [Invalid_argument] guards the helper's own precondition for callers that
      construct literals by hand. *)
