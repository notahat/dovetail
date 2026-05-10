# Dovetail

Project-specific conventions. The user's global rules in
`~/.claude/CLAUDE.md` apply except where overridden here. Conventions are
still settling — refine this file as cases come up.

## Orientation

- `docs/plans/NN-name.md` is where design lives. `00-initial-plan.md` is
  the foundational document; slice plans accumulate as `01-...`, `02-...`
  and so on, with the file number matching the slice number. Read the
  relevant slice plan before writing code for it.
- `lib/` for library code, `bin/` for the executable, `test/` for tests.
- Every module in `lib/` has both a `.ml` and a `.mli`. The `.mli` is the
  public-API documentation: module-level overview at the top, header
  comment per `val`. Doc comments live in the `.mli` only.

## Naming

- Spell things out. Use `environment`, not `env`. Use `transaction`, not
  `txn`. Use `table_name` rather than bare `name` when the kind of name is
  ambiguous from context. We're early enough that clarity matters more
  than terseness.
- Apply this to function names, parameter names, and type names alike.
- Single-letter names are out, per the global rules — no `f`, `x`, `xs`,
  `i`. Pick a real name even in short closures.
- Use the OCaml `.t` convention: a module's primary type is named `t`
  (so callers write `Schema.t`, `Catalog.t`, etc.). This is the one place
  where extreme brevity is the right call — the module name carries the
  meaning.
- Use submodules when a module owns multiple peer concepts that each
  deserve a namespace. `Value.Kind.t` is the example: it sits alongside
  the future `Value.t` without constructor clashes.

### Exceptions where short forms stay

- `iter_seq`, and similarly `iter` in any function that walks a
  collection. `iter` is universal in OCaml stdlib (`List.iter`,
  `Seq.iter`, `Hashtbl.iter`) — spelling it out would fight idiom.
- `map` as a type or function name. It's already a full word; the
  unfortunate overlap with `List.map` is unavoidable and renaming would
  obscure intent.
- `subDB` in doc comments referring to LMDB's named sub-databases. That
  is LMDB's own term; we keep it so prose lines up with their docs.

If you find yourself wanting to add to this list, prefer spelling out
unless the short form is genuinely conventional in OCaml or the
underlying tool's vocabulary.

## Tooling

- OCaml 5.2 in a local opam switch at the project root.
- Run dune commands via `opam exec -- dune ...` so the local switch's
  environment is set up for that one command. Avoid the
  `eval $(opam env) && dune ...` form: it works, but it interferes with
  Claude Code's per-command permission allowlist.
- Build: `opam exec -- dune build`. Tests: `opam exec -- dune test`.
  Format: `opam exec -- dune build @fmt --auto-promote`.
- Run the formatter before considering a step done; it has opinions and
  will adjust line breaks and comment wrapping.
- Test framework: `alcotest`. Parser library: `angstrom` (arrives in
  slice 1 step 8).

## Workflow

- Slice plans break into numbered steps. Each step is one commit, ends
  with tests passing, leaves the project in a working state.
- TDD where the global rules call for it: failing test first for behaviour
  changes; skip when there is no testable behaviour (config, formatting,
  pure renames).
- Don't make conventions stricter than they need to be. When something
  doesn't fit, surface it for discussion rather than silently working
  around it.
