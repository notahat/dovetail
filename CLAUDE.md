# Dovetail

Project-specific conventions. The user's global rules in
`~/.claude/CLAUDE.md` apply except where overridden here. Conventions are
still settling — refine this file as cases come up.

## Orientation

- `docs/plans/NN-name.md` is where design lives. `00-initial-plan.md` is
  the foundational document; slice plans accumulate as `01-...`, `02-...`
  and so on, with the file number matching the slice number. Read the
  relevant slice plan before writing code for it.
- `lib/` for library code, organised into seven sub-libraries under
  their own dune libraries: `core`, `storage`, `plan`, `ddl`,
  `surface_ra`, `execution`, `frontend`. `bin/` for the executable.
  `test/` mirrors `lib/` (`test/core/`, `test/storage/`, …), plus
  `test/helpers/` for shared test infrastructure and
  `test/integration/` for end-to-end tests that cross library
  boundaries.
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
  (so callers write `Relation.t`, `Catalog.t`, etc.). This is the one place
  where extreme brevity is the right call — the module name carries the
  meaning.
- Use submodules when a module owns multiple peer concepts that each
  deserve a namespace, so each peer's primary type can be `.t` without
  constructor clashes between them.

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

### Internal `kind` vs user-facing `type`

The static shape of a value goes by two names depending on which side
of the wall you're on. They are the same concept — see
[`docs/type-system.md`](docs/type-system.md) for the framing.

- **Inside the code**, the name is `kind`: `Scalar.kind`, `Row.kind`,
  `Relation.kind`. OCaml's `type` is a keyword, so we cannot use it
  for our own identifiers; `kind` is the disambiguating choice and
  `type-ladder.md` documents the as-built shape.
- **At the surface** — REPL output, the `type` pipe operator, error
  messages, user-facing docs, this project's prose for users — the
  name is `type`. That's the word a database user expects.

Apply the split deliberately:

- Code identifiers, doc comments inside `.mli` files, and references
  to specific OCaml identifiers use `kind`.
- User-facing strings (REPL prompts, errors, `:`-command output until
  it's retired, anything a user reads) use `type`.
- Design docs in `docs/` use `type` in prose and `kind` only when
  pointing at OCaml identifiers. `type-ladder.md` is the documented
  exception — it describes the as-built code and uses `kind`
  throughout because that's the code's vocabulary.

When introducing a new module or value at this rung, follow the
existing code convention (`kind` / `value` / `t`). When writing a new
user-facing string, pick `type`. If a piece of prose lives in both
worlds — say, a doc comment that describes an operator a user
invokes — write for the user (`type`) and add a parenthetical
(`internally: kind`) only if the OCaml-side name needs to be visible
from that paragraph.

## Comments

- Don't reference slices or steps in code or comments. The plan
  scaffolding is for `docs/plans/`, not the code — "when things were
  added isn't relevant to someone reading the code." Describe current
  limitations or future directions in their own terms ("currently only
  supports X", "multi-row literals will…"), not by citing the slice
  that introduced or will introduce them.

## Error messages

- Every user-facing error string starts with a prefix that names the
  user-facing concept the error belongs to: `Prefix: detail` or
  `Prefix: operation: detail` when the operation is worth naming
  (`Translate: insert into "orders": ...`,
  `Eval: insert into "orders": ...`, `Projection.resolve: ...`,
  `Relation.assemble_tuple: ...`, `DDL: drop table "orders": ...`). The
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
- **Per-module alias.** `module Scalar = Dovetail_core.Scalar` for each
  used module; references stay unqualified (`Scalar.value`). Smaller
  per-file diff and no prefix noise at every type signature and pattern
  match.

**Rule of thumb:** library alias by default; per-module alias for
`core` (and any future library where the prefix would be noise rather
than signal). `core` types — `Scalar`, `Row`, `Relation`, `Expression`,
`Relation_literal` — are pervasive enough that a `Core.`
prefix on every reference would add noise without signal. Localised
sublibraries (`storage`, `plan`, `ddl`, `surface_ra`, `execution`,
`frontend`) carry meaningful prefixes, so the library-alias form is
the default — `Storage.Engine.X`, `Plan.Logical.X`,
`Execution.Eval.X`, `Frontend.Cli.X`.

**Tests open the library under test; everything else gets the
normal aliases.** A test that exercises `Logical.classify` opens
`Dovetail_plan` and refers to `Logical.classify` unqualified. Other
libraries the test happens to mention — say `Execution.Eval` for a
pipeline subtest inside a translate test, or `Plan.Physical.t` from
a `surface_ra` test — get the same `module X = Dovetail_X` library
aliases that lib code uses, and the call sites pay the prefix.
`core` types stay on per-module aliases everywhere
(`module Scalar = Dovetail_core.Scalar`) for the same noise-vs-signal
reason lib code uses them. Integration tests in `test/integration/`
have no single SUT, so all libraries get the `module X = …`
treatment there.

`test/helpers/` is library-shaped (a helpers library), so it
follows lib code's convention straight through — no opens.

## Tooling

- OCaml 5.2 in a local opam switch at the project root. The switch's
  `bin/` is already on `PATH` in the shell, so `dune` and friends can be
  invoked directly — no `opam exec --` prefix needed.
- **Test/build loop is the `dune-watcher` skill**
  (`~/.claude/skills/dune-watcher/`). See the skill for the watcher
  start command, the wait-for-rebuild protocol, the rules for what NOT
  to run while the watcher is up, and the failure modes. The wait
  script lives in the skill at
  `~/.claude/skills/dune-watcher/scripts/wait-for-watcher.py` — invoke
  it from there; there is no project-local copy. The empirical
  findings behind the script are in the skill's
  `references/dune-watcher.md`.
- **Running the binary.** `./dovetail [--demo-data] [<env-path>]` execs
  the prebuilt artifact and is safe to run while the watcher is up
  (the wrapper does not invoke `dune exec`, so there is no lock
  collision; the watcher keeps the artifact fresh).
- Formatting on `.ml` / `.mli` edits is handled by a PostToolUse hook
  that runs `ocamlformat --inplace`; no manual format step is needed
  during normal edit cycles. Run the formatter before considering a
  step done — it has opinions and will adjust line breaks and comment
  wrapping.
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
