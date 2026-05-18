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

## Error messages

- Every user-facing error string starts with a prefix that names the
  user-facing concept the error belongs to: `Prefix: detail` or
  `Prefix: operation: detail` when the operation is worth naming
  (`Translate: insert into "orders": ...`,
  `Eval: insert into "orders": ...`, `Projection.resolve: ...`,
  `Schema.assemble_tuple: ...`, `DDL: drop table "orders": ...`). The
  prefix usually matches a module name, since the user-facing concept
  and the module that implements it usually line up. When they don't —
  e.g. `Ddl_executor` is implementation detail, but the user typed a
  `:` DDL statement and is in "DDL land" — the prefix names the
  user-facing concept (`DDL:`), not the module.
- Prefer `failwith` for user-reachable failures; reserve
  `invalid_arg` for argument-shape precondition violations that callers
  could and should have prevented (e.g. `assemble_tuple`'s length checks).
- `assert false` (with a one-line comment naming the invariant) is the
  right form for arms the layering upstream is supposed to guarantee.
  These are not the same as user-reachable failures; treating them as
  `failwith` makes them masquerade as recoverable errors.
- A `(* TODO(slice-N) *)` or `(* TODO(composite-pk) *)`-style marker
  beats prose for slice-1/slice-6 limitation notes — a searchable token
  shortens the lift when the limitation is addressed.

## Cross-library aliases

The sub-library layout means lib-internal files reach across library
boundaries to use modules from sibling sub-libraries. Two styles:

- **Library alias.** `module Ddl = Dovetail_ddl` at the top of the file;
  references become `Ddl.Statement.t`. The prefix keeps group membership
  visible at the call site — "this is the DDL vocabulary" — which is
  worth signal when the sibling library names a localised concern.
- **Per-module alias.** `module Value = Dovetail_core.Value` for each
  used module; references stay unqualified (`Value.t`). Smaller per-file
  diff and no prefix noise at every type signature and pattern match.

**Rule of thumb:** library alias by default; per-module alias for
`core` (and any future library where the prefix would be noise rather
than signal). `core` types — `Value`, `Schema`, `Relation`,
`Expression`, `Relation_literal` — are pervasive enough that a `Core.`
prefix on every reference would add noise without signal. Localised
sublibraries (`ddl`, future `storage`/`plan`/...) carry meaningful
prefixes, so the library-alias form is the default.

## Tooling

- OCaml 5.2 in a local opam switch at the project root. The switch's
  `bin/` is already on `PATH` in the shell, so `dune` and friends can be
  invoked directly — no `opam exec --` prefix needed.
- Single-shot commands (only when no watcher is running): build with
  `dune build`, run tests with `dune test`, format with
  `dune build @fmt --auto-promote`.
- **Watcher is the default test loop.** Start `dune runtest -w` (short
  for `--watch`) once as a long-lived background task; it rebuilds and
  re-runs the test suite on every file save. It also keeps `_build/`
  artifacts fresh so merlin/ocaml-lsp gets live diagnostics through the
  RPC socket at `_build/.rpc/dune`; without watch mode the editor LSP
  runs on stale artifacts and reports phantom errors.
- **Claude must never run `dune test` / `dune build` / `dune build @fmt`
  while the watcher is up.** Those one-shots forward to the watcher
  daemon and hang (the daemon only does what it was configured to do,
  not what the one-shot asked). Read test results from the watcher's
  output instead; format with `ocamlformat --inplace <file>` directly
  (the PostToolUse hook does this automatically on `.ml` / `.mli`
  edits).
- If the watcher is missing or dies, restart it the same way: one
  backgrounded `dune runtest -w`. Do not start a second watcher or fall
  back to ad-hoc `dune test` runs.
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
