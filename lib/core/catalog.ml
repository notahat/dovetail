type kind = { relation_kinds : (string * Relation.kind) list }
type value = { relations : (string * [ `Set ] Relation.t) list }

let format_kind formatter (kind : kind) =
  match kind.relation_kinds with
  | [] -> Format.pp_print_string formatter "catalog {}"
  | _ ->
      let format_entry formatter (table_name, relation_kind) =
        Format.fprintf formatter "%s: %a" table_name Relation.format_kind
          relation_kind
      in
      let separator formatter () = Format.pp_print_string formatter ", " in
      Format.pp_print_string formatter "catalog { ";
      Format.pp_print_list ~pp_sep:separator format_entry formatter
        kind.relation_kinds;
      Format.pp_print_string formatter " }"

(* Rendered through a vertical Format box so each entry breaks onto its own
   line. Each entry opens its own vbox at the catalog's content column and
   emits the [name = ] prefix inside that box, then calls
   [Relation.format_into] so the relation's rows-cuts indent relative to
   the entry's start column (catalog indent + 2) rather than the [relation]
   keyword's column. The closing brace uses [@;<0 -2>] to drop back to the
   column where the catalog box opened. *)
let format formatter (value : value) =
  match value.relations with
  | [] -> Format.pp_print_string formatter "catalog {}"
  | _ ->
      let format_entry formatter (table_name, relation) =
        Format.fprintf formatter "@[<v 2>%s = %a@]" table_name
          Relation.format_into relation
      in
      let separator formatter () = Format.fprintf formatter ",@," in
      Format.fprintf formatter "@[<v 2>catalog {@,";
      Format.pp_print_list ~pp_sep:separator format_entry formatter
        value.relations;
      Format.fprintf formatter "@;<0 -2>}@]"
