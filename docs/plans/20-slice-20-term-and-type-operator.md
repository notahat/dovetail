# 20 — Slice 20: Term carrier and the type operator

First substantive slice of the [type-system work](../type-system.md).
Introduces `Core.Term`, the unified pipeline-payload carrier; threads
it through every IR layer; lands the `type` operator at the relation
rung; retires `:describe`.

Depends on [slice 19](19-slice-19-collapse-mutations-into-pipeline.md)
— the pipeline is already one universe by the time this slice runs.

## Goal

After this slice, a pipeline's evaluation result is a `Term.t`, not a
`_ Relation.t`. The user can type `users | type` to see the relation
type of `users`; the `:describe users` form goes away.

`Term.t` is the rung-aware union of "anything that flows through a
pipe or falls out the end of one." In this slice it has two arms:

```ocaml
type 'tag t =
  | Relation_value of 'tag Relation.t
  | Relation_kind  of Relation.kind
```

Other arms grow incrementally as later slices need them.

## Scope

- New module `lib/core/term.ml{,i}` defining `Term.t` (two arms) and
  `Term.format`. Renderer dispatches per arm; `Relation_kind` formats
  in the new surface syntax (`(id: int64, name: string, primary key
  (id))`).
- New kind formatter `Relation.format_kind` and any scalar/row pieces
  it needs (`Scalar.format_kind` printing lowercase keywords —
  `int64`/`string`/`bool` — replacing the capitalised
  `Scalar.kind_to_string` form in user-facing output).
- New AST node `Type of { input : t }` in `Ast.t`. New Logical
  node `Type_op` and Physical node ditto. Lower/Translate pass them
  through; they sit at the root of a pipeline only (nothing in slice
  20's grammar consumes a kind on the left).
- `Eval.eval`'s signature becomes `... -> Term.t`. The Type case
  reads the input's static `Relation.kind` (via a
  `Physical.kind_of` helper) without materialising the input — no
  cursors open, no rows pulled. Every other case wraps its relation
  result as `Term.Relation_value`.
- Parser learns one new keyword: `type` as a unary pipe operator.
- REPL's single print path dispatches on `Term.t` arms.
- `:describe` removed from `lib/ddl/`: parser rule, AST constructor,
  executor case, and any tests. `lib/ddl/` is smaller but still
  present (other `:`-statements remain).
- "type: input is already a type" error: `users | type | type` is
  rejected. Implementation lives wherever it's most natural — likely
  at the lowering boundary when the second Type_op's input is itself
  a Type_op. Test it.

## Out of scope

- Scalar / row / catalog rungs of `type`. They come online
  automatically in [slice 21](21-slice-21-literal-syntax-flip.md) when
  the literal forms become valid pipeline sources, and in
  [slice 23](23-slice-23-catalog-rung.md) for catalog. `Term.t` only
  grows arms for new things this slice constructs.
- Literal-syntax changes (the curly-brace relation literal stays
  as-is).
- `Core.Catalog`. Catalog rung lands in slice 23 alongside its
  consumer operators.

## Key design decisions made during planning

- **B-style threading: `Term.t` reaches into Lower/Translate/Physical.**
  Every IR layer's *output* type changes shape — though in this slice
  the only non-relation case is `Type_op`. Hybrid C (Term only at the
  Eval boundary) was considered and rejected: we want to commit to the
  unified universe sooner rather than later. See [type-system.md
  §"pipe stages across the ladder"](../type-system.md).
- **No GADTs for the IR.** Flat sums with the lowering pass
  responsible for producing well-formed combinations; bugs produce
  clear runtime failures rather than silent wrong behaviour. Revisit
  if the operator zoo grows enough that the type-system protection
  starts earning its cost.
- **`Term.t` lives in `lib/core/`.** Vocabulary type for the whole
  ladder; same reasoning that puts Scalar/Row/Relation there. Core
  doesn't consume Term itself; execution produces it.
- **Flat sum, nominal constructors, grow incrementally.** Pattern
  matches are grouped by face (kinds first, then values) for
  readability. Polymorphic variants and GADTs both rejected for the
  usual idiom-vs-cost reasons.
- **No `Core.Catalog` in this slice.** Slice 23 introduces it
  alongside the operators that consume it.

## Notes for follow-on slices

- Slice 21 grows `Term.t` by four arms (Scalar_value, Scalar_kind,
  Row_value, Row_kind) as new literal sources come online.
- Slice 22 doesn't touch `Term.t` — `create_table`/`drop_table` produce
  relation results, which fit the existing `Relation_value` arm.
- Slice 23 grows `Term.t` by two arms (Catalog_value, Catalog_kind)
  and introduces `Core.Catalog`.
- The doc's note about "type applied to a type is an error" needs a
  test in this slice. Implementation site is a design call worth
  resolving in the slice plan.
