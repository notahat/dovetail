(** A database's schema and its data, viewed as a single value.

    A catalog is the top of the type ladder: the static [kind] enumerates the
    relation kinds present (one per base table), and the runtime [value] pairs
    each table name with the relation that holds its rows. The two faces line up
    exactly — every entry in a [value] has a matching entry in the corresponding
    [kind].

    Both [kind] and [value] are ordered byte-sorted by table name, matching the
    cursor order [Storage.Catalog] yields when listing tables. This is the
    canonical iteration order; readers and renderers may rely on it.

    Cross-table refinements (foreign keys, cross-table check clauses) are
    deliberately absent. The syntax exists in the surface language but is not
    yet represented here; it will arrive in a dedicated slice once the semantics
    are settled. *)

type kind = { relation_kinds : (string * Relation.kind) list }
(** The shape of a catalog: an ordered association list mapping each base
    table's name to its {!Relation.kind}. Sorted byte-wise by table name. *)

type value = { relations : (string * [ `Set ] Relation.t) list }
(** The runtime contents of a catalog: an ordered association list mapping each
    base table's name to a set-tagged {!Relation.t} carrying the table's rows.
    Sorted byte-wise by table name. Every relation in a [value] is [`Set]-tagged
    because every base table in storage is currently a set; a per-entry
    multiplicity discriminator joins this type when a bag-table mode lands.

    The row sequence inside each entry's {!Relation.t} is lazy and tied to the
    read transaction that produced the catalog; it must be consumed within that
    transaction's scope. *)

val format_kind : Format.formatter -> kind -> unit
(** [format_kind formatter kind] writes [kind] to [formatter] in the surface
    catalog-type syntax: [catalog \{ name1: T1, name2: T2, ... \}] where each
    [Ti] is the corresponding relation type rendered via
    {!Relation.format_kind}. An empty kind renders as [catalog \{\}].
    Single-line; no trailing newline. *)

val format : Format.formatter -> value -> unit
(** [format formatter value] writes [value] to [formatter] in the surface
    catalog-literal syntax: [catalog \{ name1 = R1, name2 = R2, ... \}] where
    each [Ri] is the relation rendered via {!Relation.format}, fully expanded
    with its rows. An empty value renders inline as [catalog \{\}]; a non-empty
    value breaks across lines, each entry on its own line indented by two
    spaces. Nested relations indent further still — {!Relation.format} is itself
    a Format-box renderer, so its rows-block auto-indents under the catalog's
    own vertical box. Materialises every relation's row sequence eagerly;
    transaction scope still applies. No trailing newline. *)
