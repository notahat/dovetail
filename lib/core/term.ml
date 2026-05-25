type 'tag t =
  | Scalar_value of Scalar.value
  | Scalar_kind of Scalar.kind
  | Row_value of Row.t
  | Row_kind of Row.kind
  | Relation_value of 'tag Relation.t
  | Relation_kind of Relation.kind
  | Catalog_value of Catalog.value
  | Catalog_kind of Catalog.kind
  constraint 'tag = [< `Set | `Bag ]

(* Placeholder rendering for the catalog arms; replaced by a real
   [Catalog.format] in a follow-up step. *)
let format_catalog_value_placeholder formatter (_value : Catalog.value) =
  Format.pp_print_string formatter "catalog { ... }"

let format_catalog_kind_placeholder formatter (_kind : Catalog.kind) =
  Format.pp_print_string formatter "catalog { ... }"

let format formatter = function
  | Scalar_value value -> Scalar.format formatter value
  | Scalar_kind kind -> Scalar.format_kind formatter kind
  | Row_value row -> Row.format formatter row
  | Row_kind kind -> Row.format_kind formatter kind
  | Relation_value relation -> Relation.format formatter relation
  | Relation_kind kind -> Relation.format_kind formatter kind
  | Catalog_value value -> format_catalog_value_placeholder formatter value
  | Catalog_kind kind -> format_catalog_kind_placeholder formatter kind
