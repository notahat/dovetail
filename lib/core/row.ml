type field = { name : string; kind : Value.kind; qualifier : string option }
type kind = field list
type data = Value.data array
