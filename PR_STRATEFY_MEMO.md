# PR Strategy Memo

This memo records the current upstreaming strategy for the local
`dumpcases-json` / `dumppaths-json` work and the related bootstrap build fix.

## Current Fork Delta

The fork currently contains four distinct changesets:

1. `--dumppaths-json` CLI/session plumbing
2. canonical intrafunction path export from elaborated case trees
3. runtime path-hit instrumentation for Chez
4. bootstrap/build-path stabilization for `build/exec/idris2`

These should not be upstreamed as one PR.

## What Actually Broke in the Chez Build

The observed generated-scheme failure looked like a compiler naming bug:

- `DataC-45String-n--3989-9708-u--linesHelp`
- `PreludeC-45Types-n--10177-9486-u--go`

However, the practical root cause for the failing `make build/exec/idris2`
path was that the bootstrap app build was not forced to use the repo-local,
freshly rebuilt TTC set. That allowed the bootstrap compiler to see stale
externally installed TTC artifacts.

The minimal fix is in `Makefile`:

- build the app with `IDRIS2_PATH=${IDRIS2_BOOT_PATH}`
- build the app with `IDRIS2_PREFIX=${IDRIS2_BOOT_PREFIX}`

This fix is small, reviewable, and independently useful.

## Recommended Upstream PR Order

### PR 1: Bootstrap build stabilization

Scope:

- `Makefile` only

Pitch:

- Fixes a real bootstrap/app-build reproducibility issue
- Ensures the app build uses the same repo-local TTC world as the library build
- Narrow, low-risk, and easy to review

Why this should go first:

- It is independent of coverage work
- It removes noise from later path-coverage discussion
- It turns the fork into a stable compiler artifact without hacks

### PR 2: `--dumpcases-json`

Scope:

- machine-readable static case-tree export
- branch/node-oriented JSON only

Pitch:

- Structured export for tooling
- No change to elaboration semantics
- No claim about runtime coverage yet
- Easier to review than path export

Required framing:

- This is a static export interface
- This is not a totality-semantics change
- This is not CFG/path explosion work

### PR 3: `--dumppaths-json` as experimental

Scope:

- canonical intrafunction root-to-leaf paths
- export-only interface

Pitch:

- Not general CFG path enumeration
- Not interprocedural
- Not recursion unrolling
- Not SMT/path-condition solving
- Just finite root-to-leaf obligations over the elaborated pre-optimization
  case-tree layer

Required framing:

- "canonical intrafunction paths"
- "finite case-tree export"
- "experimental interface"
- "machine-readable semantic obligation layer"

Current local implementation note:

- the working exporter basis today is `treeCT`, not `treeRT`
- this is because the validated package-build exporter currently behaves
  correctly on `treeCT`

This is the key point: upstream should review this as a narrow semantic
export, not as an ambitious whole-program path-coverage proposal.

### PR 4: runtime path-hit instrumentation

Scope:

- backend/runtime coupling
- stable `path_id` hit emission

Pitch:

- Downstream exact path coverage needs runtime hits
- This is separable from static export
- Keep it out of the initial export PR unless explicitly requested

## Review Positioning

When discussing `--dumppaths-json`, avoid saying "path coverage" first.
Lead with:

1. finite case-tree obligation export
2. static semantic layer
3. downstream tooling use-case
4. non-goals

That framing makes the ask much smaller and more acceptable.

## What to Show as Evidence

The strongest evidence set is:

1. the compiler builds cleanly without the hack wrapper
2. `--dumppaths-json` produces stable machine-readable output
3. downstream tools can list untested paths from that export
4. EtherClaw/`lazy * ask --steps=4` can consume the resulting
   `Missing paths` / `claim_admissible` contract

Current local evidence already includes:

- `make build/exec/idris2` succeeding without hack wrapper
- `tests/codegen/dumppaths001` passing
- `tests/codegen/dumppaths002` passing
- CoreCoverage exact path report working against the built compiler
- EvmCoverage and DfxCoverage package-level path report support
- EtherClaw HardHarness integration for path-aware `steps=4`

## Non-goals to State Explicitly

For upstream acceptance, state these explicitly:

- no interprocedural path expansion
- no recursion unrolling
- no loop-sensitive CFG path enumeration
- no SMT path-condition generation
- no change to totality semantics
- no mandatory runtime coverage feature in the first export PR

## Practical Submission Plan

1. Submit the Makefile/bootstrap fix first.
2. Wait for merge or at least reviewer confidence.
3. Submit `--dumpcases-json`.
4. Keep `--dumppaths-json` as experimental and explicitly narrow.
5. Hold runtime path hits as a follow-up.

## Internal Note

If upstream is hesitant about `--dumppaths-json`, the fallback position is:

- merge `--dumpcases-json`
- keep `--dumppaths-json` in the fork
- continue proving usefulness through CoreCoverage / EvmCoverage / DfxCoverage

That still preserves the main strategic goal: demonstrate that path obligations
over Idris2 case trees are computationally tractable and downstream-useful.
