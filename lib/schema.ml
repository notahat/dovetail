type field = { name : string; kind : Value.Kind.t }
type t = { fields : field list; primary_key : string list }
