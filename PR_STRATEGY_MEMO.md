# Upstream PR Strategy Memo

Records the strategy for upstreaming the local fork changes (dumpcases-json,
dumppaths-json, runtime path hits, JS source maps) into idris-lang/Idris2.

## 0. Measurement axis (read this first)

The fork branched from upstream at **`d83bc7d` (2026-01-10)** and upstream has
moved ~6 months ahead since (`origin/main` at `f33475d`, 2026-06-20).

**Always measure the fork delta with the 3-dot diff (`origin/main...HEAD`), not
the 2-dot diff (`origin/main..HEAD`).**

- `origin/main..HEAD`  → 271 files, +3760/-2317. **Misleading.** ~245 of those
  files (refc/*.c, libs/base, Core/Unify, docs, 162 `expected` files) are
  *upstream's* 6 months of progress shown as if we deleted them. They are not
  our changes.
- `origin/main...HEAD` → **33 files, +2011/-39.** This is what we actually added.

If a reviewer ever sees the 2-dot number, the PR is dead on arrival. Rebase onto
current `origin/main` before doing anything, so the two diffs converge.

## 1. Real fork delta (3-dot, attributed)

Our commits since the merge base:

| commit | summary |
| --- | --- |
| `729daa4` | Add dumpcases JSON export flag |
| `8a0fef1` | Add dumppaths-json export and stabilize bootstrap builds |
| `a9dec97` | Stabilize dumppaths export and document upstream path |
| `20e06ab` | Stabilize dumppaths exporter for large packages |
| `cf57c40` | emit recordPathHit in the ES/react-native backend |
| `b27ae31` | Add source map support for --cg javascript backend |

17 of the 33 changed files are genuine upstreamable source; the rest are tests,
docs, or private artifacts to drop.

## 2. Split plan — 1 lead PR, 2 optional follow-ups

Revised after auditing flag coupling and naming leakage.

### Dropped: dumpcases-json (former PR-1)

`--dumpcases-json` predates the dumppaths invention. Audit shows `DumpCasesJSON`
and `DumpPathsJSON` are **sibling flags that share no code** — `dumpPathsJson`
consumes the case tree directly and never calls `dumpcasesjson`. So PR-2 does
**not** depend on it. `--dumpcases-json` is just a JSON variant of the existing
`--dumpcases` (an early prototype before "canonical path obligation" became the
real abstraction). Low upstream value, no dependents. **Do not upstream it;
candidate for deletion from the fork too.**

### The plan

```
PR-2 (now the lead): --dumppaths-json     the actual invention — the only must-upstream
   └─ PR-3 (optional): runtime path-hit instrumentation primitive
PR-4 (independent, optional): JS source map
```

| PR | upstreamable files | pitch to upstream |
| --- | --- | --- |
| **PR-2 dumppaths-json** (lead) | `src/Compiler/CompileExpr.idr`, `src/Compiler/Scheme/Chez.idr`, `src/Compiler/Scheme/Common.idr`, `src/Idris/ProcessIdr.idr`, `src/Compiler/Common.idr`, `src/Idris/CommandLine.idr` (this flag only), `src/Core/Options.idr` + `src/Idris/SetOptions.idr` (this flag only), `Makefile` (bootstrap parts) | export compiler-known canonical intrafunction path obligations as JSON so external tooling has a stable denominator |
| **PR-3 path-hit primitive** | `src/Compiler/ES/Codegen.idr` (`prim__recordPathHit`, `cf57c40`); the Scheme `RecordPathHit` parts of `Chez.idr`/`Common.idr` if also extracted | a generic opt-in runtime instrumentation hook, default-off, zero perf impact |
| **PR-4 source map** | `src/Compiler/ES/SourceMap.idr`, `src/Compiler/ES/TailRec.idr`, `src/Compiler/ES/Codegen.idr` (`b27ae31`), `src/Compiler/ES/Node.idr`, `src/Compiler/ES/Javascript.idr`, `src/Compiler/ES/Doc.idr`, `idris2api.ipkg` | source maps for `--cg javascript`, better debugging |

Note: `Common.idr`, `Options.idr`, `SetOptions.idr`, `CommandLine.idr` are touched
by several flags. Carry only the lines belonging to each PR's feature — do not
move the whole file, and do not drag the dropped dumpcases-json lines along.

### De-EtherClaw-ify PR-3 (the naming/comment audit)

Audit result: the *identifiers* are already neutral and follow upstream
convention — `prim__recordPathHit`, `globalThis.__idris2_recordPathHit`,
`dumppathshits`, `RecordPathHit`. The leak is in the **comments**, which describe
EtherClaw's use case ("the View runs on the device", "react-native",
"coverage real: numerator/denominator", "the device coverage"). Upstream reads
that as "a feature for one specific downstream tool" and bounces it.

Fix before PR-3:

- Present it as a **generic runtime instrumentation primitive**: "inject a
  user-overridable hook at each canonical case-tree path; no-op unless a runtime
  hook is installed."
- Strip all references to View / react-native / Hermes-JSC-as-our-device /
  coverage numerator-denominator from the *upstream* comments. Coverage is *an*
  application, mentioned as motivation at most, not the definition.
- Keep `--dumppathshits` only if it reads as a general "runtime path hits"
  facility; otherwise fold the instrumentation hook into PR-2's story and let
  the JSON consumer compute hits externally.

## 3. Drop from any upstream branch (private artifacts)

- `PR_STRATEFY_MEMO.md` — old, typo'd; superseded by this file (this file should
  also stay fork-only, not in PR branches)
- `docs/tasktrees/20260406-chez-generated-scheme-bug.toml` — EtherClaw private
- `support/chez-audit-unbound-symbols.sh` — local debugging script

## 4. Levers to get merged (priority order)

1. **Rebase onto current `origin/main` first.** Collapses the phantom 245-file
   drift; makes 2-dot == 3-dot.
2. **New flags must not change default output by a single byte.** The 162
   `expected` churn in the 2-dot view is the drift; verify the rebased fork only
   adds *new* test directories (e.g. `tests/idris2/dumppaths001/`) and leaves
   existing `expected` untouched. If a real `expected` changes, the flag is
   altering default behavior — fix that.
3. **Each PR ships CHANGELOG_NEXT.md + docs + tests** (Idris2 PR template
   requirement). Add a `docs/source/reference/` entry per new flag.
4. **Open a proposal issue before the compiler PRs.** Title around the general
   need: "machine-readable export of path/case obligations for external coverage
   tooling." Get maintainer direction before PR-2.
5. **Generalize the audience.** Argue for *dependent-type-aware coverage tooling*
   in general, not "for EtherClaw." The "Why Idris2, not Lean" framing (a
   language that makes executed programs the object of measurement) is the
   upstream-facing motivation.

## 5. Bootstrap-build fix context (PR-2 ride-along)

The `make build/exec/idris2` failure that looked like a compiler naming bug
(`DataC-45String-n--3989-...`) was actually the bootstrap app build not being
forced to use the repo-local freshly-rebuilt TTC set, letting it pick up stale
installed TTC. The minimal fix lives in `Makefile`. Keep this scoped to PR-2 and
explain it as a bootstrap-determinism fix, not a codegen change.
