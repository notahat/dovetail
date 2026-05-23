type 'tag t =
  | Relation_value of 'tag Relation.t
  | Relation_kind of Relation.kind
  constraint 'tag = [< `Set | `Bag ]

let format formatter = function
  | Relation_value relation -> Relation.print ~formatter relation
  | Relation_kind kind -> Relation.format_kind formatter kind
