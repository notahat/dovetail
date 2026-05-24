type 'tag t =
  | Scalar_value of Scalar.value
  | Scalar_kind of Scalar.kind
  | Row_value of Row.t
  | Row_kind of Row.kind
  | Relation_value of 'tag Relation.t
  | Relation_kind of Relation.kind
  constraint 'tag = [< `Set | `Bag ]

let format formatter = function
  | Scalar_value value -> Scalar.format formatter value
  | Scalar_kind kind -> Scalar.format_kind formatter kind
  | Row_value row -> Row.format formatter row
  | Row_kind kind -> Row.format_kind formatter kind
  | Relation_value relation -> Relation.format formatter relation
  | Relation_kind kind -> Relation.format_kind formatter kind
