module Storage = Dovetail_storage
module Plan = Dovetail_plan
module Catalog = Dovetail_core.Catalog
module Scalar = Dovetail_core.Scalar
module Term = Dovetail_core.Term

(* Compute [input]'s static kind and hand [continue] the corresponding
   [Term.*_kind] arm. [Scalar_literal], [Row_literal], and [Catalog_source]
   short-circuit to their own per-rung kind directly; every other shape is
   a relation, so the kind comes from {!Plan.Physical.kind_of}. No cursors
   are opened in any case. The catalog callback reads from the live
   [Storage.Catalog], so a missing-table reference inside [input] surfaces
   with the same wording the relational cases produce at scan time.

   TODO(kind-of-uniform): the kind_of family is split per rung -- scalar
   via {!Scalar.kind_of}, row built from a row literal's fields, catalog
   assembled here, relation via {!Plan.Physical.kind_of}. Unifying these
   under a single dispatch (perhaps a polymorphic [Term.kind_of] returning
   a kind-arm-tagged term) is a future refactor; today each arm wears its
   own seam. *)
let evaluate environment transaction ~input continue =
  match input with
  | Plan.Physical.Scalar_literal value ->
      continue (Term.Scalar_kind (Scalar.kind_of value))
  | Plan.Physical.Row_literal { fields } ->
      continue (Term.Row_kind (Eval_row_literal.kind_of_fields fields))
  | Plan.Physical.Catalog_source ->
      let relation_kinds =
        Storage.Catalog.list_table_names environment transaction
        |> List.map (fun table_name ->
            match Storage.Catalog.get environment transaction ~table_name with
            | Some kind -> (table_name, kind)
            (* [list_table_names] enumerated this name from the same
                  catalog subDB under the same read transaction; a missing
                  entry would be an invariant violation. *)
            | None -> assert false)
      in
      continue (Term.Catalog_kind ({ relation_kinds } : Catalog.kind))
  | _ ->
      let catalog table_name =
        Storage.Catalog.get environment transaction ~table_name
      in
      let kind = Plan.Physical.kind_of ~catalog input in
      continue (Term.Relation_kind kind)
