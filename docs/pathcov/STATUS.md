# Path-coverage work: where everything is, and how to pick it up again

Written 2026-08-16 as a hand-off to my future self. If you are reading this
months later with no memory of the work, **read this file first and in order**.
Everything below was measured, not recalled; where a claim came from a note
rather than a re-check, it says so.

---

## 0. The one-paragraph orientation

The Idris 2 fork carries three *independent* compiler features that a downstream
coverage pipeline needs all at once, and that upstream would only ever take one
at a time, if at all. This round of work (a) fixed real defects in the fork's
path identity scheme, (b) proved the fork's long-standing "cannot build from
scratch" problem is solvable, and (c) rebuilt two of the three features cleanly
on top of current upstream so they can be *studied and re-implemented by hand*.
Nothing here is submittable to upstream as-is, for a reason that has nothing to
do with code quality — see §5.

---

## 1. The branches, and what each one is for

### `shogochiai/Idris2` (this repo)

| branch | based on | what it is | state |
|---|---|---|---|
| `main` | — | the fork as it was | untouched |
| **`pathcov-stable-key`** | fork `main` (`46a31dc6b`) | **the one the downstream tool would use.** Fork features + the identity fixes below | pushed; builds; luci verified against it |
| **`pathcov-upstream-1-paths-export`** | `upstream/main` (`134412e1c`) | feature §1 alone, de-branded: `--dumppaths-json` | pushed; builds; **bootstraps from scratch**; tests pass |
| **`pathcov-upstream-2-paths-hits`** | `pathcov-upstream-1-…` | §1 + feature §2: `--dumppaths-hits` + `System.Coverage` | pushed; builds; **bootstraps from scratch**; tests pass |
| **`pathcov-notes`** | fork `main` | this file and the study documents beside it | docs only, no code |

### `shogochiai/idris2-magical-utils`
`pathcov-stable-key` — the coverage tool reads the emitted `stable_key` and
carries it into the missing-path report line. Builds (`idris2-coverage-core`,
16 modules).

### `shogochiai/luci`
`pathcov-stable-key` — the two consumer-side position-erasure stopgaps are
**deleted** and replaced by reading the emitted key. Builds (162 modules +
executable); `luci-tests` 1271 pass / 1 fail (the 1 is pre-existing and
unrelated: `REQ_LIS_CLI_MEMORY_ENCRYPTION_HONESTY_001`).

---

## 2. What was actually fixed (and how it was proven)

### 2a. The identity scheme — on `pathcov-stable-key`, all three repos

The problem, in one line: **one `path_id` was being asked to do two incompatible
jobs** — tell two declarations apart *within* a run (needs the source position)
and match the same obligation *across* two runs (needs position-independence).

- **Collision is now an error, not a silent merge.** Two declarations sharing an
  id used to be deduplicated, dropping one declaration's paths from the
  denominator — wrong in the direction that looks like success.
- **`stable_key` is emitted** = `eraseLineCol(declaration) | branch_label chain |
  ordinal`. Consumers read it; they no longer reconstruct position-independence
  by pattern-matching the id (a second definition of the key that drifts
  silently the day the id format changes).
- **Sibling case blocks get a source-ORDER ordinal `~<k>`**, and only when a
  same-named sibling exists, so no unique name changes. *The obvious alternative
  — splicing the `CaseBlock` index back in — is a regression:* that index is
  global and renumbers on unrelated edits (measured: siblings `16`/`39` became
  `151`/`174` after inserting 15 declarations above them). Relative order
  survives; the absolute index does not.
- **Paths come from the runtime tree**, which is the only place the compiler's
  inserted catch-all for a non-exhaustive `partial` function exists. Reading the
  compile-time tree silently dropped every such obligation.

Proven by: churn test (unrelated insertion → `path_id` changes, `stable_key`
does not); **negative control** (delete a clause → its `stable_key` disappears —
without this, a key that was accidentally constant would pass the churn test
vacuously); sibling test (distinct AND stable under insertion); and a sweep of
all 169 `pkgs/Luci/src` modules: 0 crashes, 0 lost ids, every path-count delta
exactly equal to its gap delta.

**Side effect worth keeping:** the runtime-tree fix surfaced two real,
previously invisible coverage gaps in `Luci.UpgradeExecution.executeUpgrade` —
`case checkExecutionReady …` handles `Left`/`Right True` but not `Right False`,
a genuine non-exhaustive match. Still unfixed in luci as far as I know.

### 2b. The bootstrap blocker — solved, on `pathcov-upstream-2-paths-hits`

The fork could not be built from a clean machine: `System.Coverage` used an
`%extern` primitive, and a *library* module's `%extern` must be understood by
whatever compiles it — including the stage-1 compiler built from the checked-in
bootstrap image, which by construction predates it.

**The fix is one word: `%foreign`, not `%extern`.** A `%foreign` is resolved at
codegen as an ordinary FFI call, so the bootstrap image needs no knowledge of
it. Supporting pieces: `support/c/idris_pathcov.{c,h}` (note `support/c/Makefile`
is `wildcard *.c`, so no Makefile edit is needed) and unconditional
`blodwen-enter-test` / `blodwen-record-path-hit` in the Chez support.

Proven by `make clean && make bootstrap SCHEME=scheme` → `bootstrap stage 2
complete`, zero errors, **with both features present**.

**This also fixed a live crash**: the hook used to be defined only when
instrumentation was on, so any program merely *calling* `enterTest` died with
`unbound identifier blodwen-enter-test`. Reproduced, then fixed, then verified.

### 2c. The instrumentation, rebuilt — same branch

The fork threads a leaf counter through a **second copy of the whole tree walk**
(~163 lines duplicated). Its own comment records that the copies drifted: the
instrumented copy lost the newtype case, so a newtype projection compiled to
`erased` and crashed the instrumented executable at load. The rebuilt version
uses **one walk with the counter in a `Ref`**, so with the flag off
`instrumentLeaf` is the identity and "no change to default output" is structural
rather than promised.

Also: output goes to `IDRIS2_PATH_HITS` at run time (precedent: `GCOV_PREFIX`,
`LLVM_PROFILE_FILE`) instead of a path baked in at compile time, so a shipped
binary carries no build-machine path.

Verified end to end: `T_LIST Main.listHead#p1` / `T_OPT Main.fromOpt#p1` —
byte-identical to the fork's own expected output.

---

## 3. Why the fork cannot simply be finished into upstream

The three features are independent and land in different places:

| | stands alone as a compiler feature? | blocked by |
|---|---|---|
| §1 `--dumppaths-json` | yes — a sibling of the existing `--dumpcases` / `--dumplifted` / `--dumpanf` / `--dumpvmcode`, and `--dump-ipkg-json` is precedent for JSON | authorship only (§5) |
| §2 `--dumppaths-hits` | yes — every mature toolchain has instrumentation; Idris 2 has none | *was* its own design; now solved |
| §3 ES source maps | yes — every JS-emitting compiler emits them; Idris 2's ES backend does not | duplicating a maintainer's existing work |

**But the downstream tool needs all three at once.** Measured: luci's web
delivery *hard-fails* without §3 —
`Idris2WebCoverage/lib/coverage.mjs:232` throws `Source map not found … Compile
with --directive sourcemap` — and android's numerator depends on §2
(`IDRIS_PATHHIT` / `__idris2_recordPathHit`), not on source maps. So the
single-feature upstream branches are experiments; **they must never become
luci's compiler.** luci's compiler stays on the fork-based branch.

Expect to maintain a fork carrying §2 and §3 even in the best case where §1
lands.

### The naming trap, if §1 is ever proposed
In Idris 2, **"coverage" already means exhaustiveness checking**
(`src/Core/Coverage.idr`, `covering`, `tests/idris2/coverage/`). Using the word
for test-coverage tooling makes every reviewer read the wrong thing. Say
"paths", "obligations", "case-tree export".

---

## 4. §3 (ES source maps): the state of the prior art

Verified 2026-08-12 against GitHub, not recalled:

- `dunhamsteve/Idris2` has branches `sourceMaps` and `sourceMaps2`.
  `sourceMaps2` tip `3d3f75177`, **2022-10-17**, 9 ahead / **993 behind**
  upstream, 8 files.
- **The duplication charge against the fork's version holds**: the file sets
  overlap in six places (`SourceMap.idr`, `Codegen.idr`, `Doc.idr`,
  `Javascript.idr`, `Node.idr`, `idris2api.ipkg`), and he has a commit
  *"Use compiler directives"* — the fork triggers via `--directive sourcemap`
  too, so even the trigger design matches.
- **He never proposed it upstream.** The only source-map PRs on
  `idris-lang/Idris2` are #3713 and #3714, both shogochiai's, both closed.
- **His own tip commit says it is unfinished**: *"Things seem a little off in the
  visualizer, so we'll need to debug. Needs tests too (somehow)."*
- **He is active now** — merged upstream PRs #3775 (2026-07-28), #3799, #3741.

So the next move on §3 is **not** code. It is to ask him: say the branch was
found, name the two gaps he himself recorded, and offer to do the ~1000-commit
rebase and write those tests if he wants it revived. A third parallel
implementation is exactly what #3714 was closed for.

---

## 5. The constraint that governs everything

`idris-lang/Idris2`'s `CONTRIBUTING.md` bans **all** contributions arising from
generative AI or LLMs, including agentic coding (added by PR #3755, merged
2026-04-04). The PR template carries an honour checkbox. shogochiai was a named
motivating example, and #3714 was closed partly because a Claude attribution had
been removed from a commit message.

**Every branch described here was written by an AI.** Therefore:

- Do **not** submit any of it upstream, and do **not** present it as
  hand-written. Ticking the box falsely is the specific act that burned this
  before.
- What these branches are *for* is understanding: they are an existence proof
  (the design works, it bootstraps, the tests pass) and a problem inventory for
  a genuine human re-implementation.
- `docs/pathcov/STABLE_KEY_REFERENCE.md` and `docs/pathcov/RATIONALES.md` beside
  this file exist for exactly that: the design with its rejected alternatives,
  its edge cases, and each feature's standalone justification.

---

## 6. If you are resuming, do these in order

1. **Re-read §5.** It has not changed unless upstream's CONTRIBUTING.md has.
2. `git fetch --all` in all three repos; the upstream branches were cut at
   `upstream/main` `134412e1c` and will have drifted.
3. Decide which thread you are on:
   - **Downstream (luci actually working):** stay on the `pathcov-stable-key`
     branches. Nothing there needs upstream's permission. Open item: the D3
     consumer changes in magical-utils and luci are on branches, **not merged**,
     and `luci/docs/contributors/pathcov-stable-key-regression-guide.md` is the
     instruction sheet for a human to review and land them.
   - **Upstream (§1):** the branch is ready to *study*. A human re-implementation
     would start from `docs/pathcov/RATIONALES.md` §1, and file an RFC issue
     before any code.
   - **Upstream (§3):** send the message described in §4. This is a human action;
     it was deliberately left undone.
4. **Verify before trusting anything here.** Each claim above names how it was
   measured; re-run it rather than believing the note.

---

## 7. Traps that cost real time (all measured, all repeatable)

- **A freshly bootstrapped compiler still resolves `System.Coverage` from the
  INSTALLED prefix** (`~/.idris2/idris2-0.8.0/base-0.8.0/`), i.e. the old base —
  you get the old error and conclude your fix failed. Point `IDRIS2_PATH` at
  `libs/prelude/build/ttc:libs/base/build/ttc`.
- **A generated program prepends the INSTALLED `support/chez/support.ss`**, not
  your edited source, so a support-side fix appears not to work until installed.
- **`make all` immediately after `make bootstrap` is a stale mix**: libs built by
  the bootstrap stage-2 compiler vs a compiler rebuilt by the old boot compiler
  disagree on `Nested` name numbering. Symptom is an `unbound identifier
  …linesHelp` whose definition IS present under a different index. Not a codegen
  bug — `make clean` first.
- **`pkill -f '<pattern>'` and `ps | grep '<pattern>'` monitors match their own
  command line.** The first self-kills (exit 144); the second never exits.
- **This sandbox blocks GitHub egress**; pushes and `gh api` need the sandbox
  disabled. The global git config is read-only, so `gh auth setup-git` fails —
  use `git -c credential.helper='!gh auth git-credential' push`.
- **luci's `pack.toml` carries a local, uncommitted `[idris2]` override** pinning
  the fork compiler. It is deliberate and pre-existing; do not "clean" it.
