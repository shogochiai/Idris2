# Three features, three independent justifications

Study notes. For each of the three things the fork carries, the question is:
**can it be motivated on its own, as a compiler feature, to someone who has never
heard of the downstream tool?** If the answer is "because our pipeline needs it",
it is not ready to propose. Each section below is the argument stripped of
provenance, plus the objection it must survive.

Evidence for the upstream-side claims was checked against `upstream/main`
(134412e1c), not recalled.

---

## 1. `--dumppaths-json` — a machine-readable dump of the elaborated case trees

### The argument, without reference to any tool

Idris 2 already ships a family of flags that dump its intermediate
representations for external inspection: **`--dumpcases`, `--dumplifted`,
`--dumpanf`, `--dumpvmcode`** (verified present upstream). The premise — that the
compiler's internal IR is worth exposing to the outside — is therefore already
accepted; this proposes one more member of that family.

What is new is the *form* and the *level*:

- **Form.** The existing dumps are `show`-formatted for human reading. Anything
  that consumes them must parse an unspecified pretty-printer output that no test
  pins. A JSON dump is stable to consume and cheap to keep stable. There is
  precedent for JSON output specifically: **`--dump-ipkg-json`** already exists.
- **Level.** `--dumpcases` prints case trees per definition. This dumps the
  *paths through* them — one record per root-to-leaf walk — which is the unit an
  external analysis actually wants, and which cannot be recovered from source.

### Why an external tool cannot do this itself

The case tree is post-elaboration. By the time it exists, `if`/`then`/`else`,
record update, `with` blocks, and pattern-matching sugar have all become case
nodes; and the compiler has resolved which branches are impossible and where it
had to insert a catch-all. A source-level analyser sees none of that and would
have to reimplement elaboration to guess it. This is the standard reason
compilers expose IR rather than telling users to re-parse the source.

### Objections it must survive

- **"Why not make `--dumpcases` emit JSON instead of adding a flag?"** A fair
  question and possibly the better proposal. The honest answer is that they are
  different levels (definitions vs paths) and changing `--dumpcases`'s format
  would break whatever depends on it today. Be ready to argue the level
  distinction, or to propose the change to `--dumpcases` instead.
- **"Does this change default behaviour?"** It must not, and does not: without
  the flag nothing is emitted.
- **Terminology.** Do **not** call this "coverage". In Idris 2, *coverage*
  already means exhaustiveness checking (`src/Core/Coverage.idr`, `covering`,
  `tests/idris2/coverage/`). Using the word for test-coverage tooling will make
  every reviewer read the wrong thing. "Paths", "obligations", "case-tree
  export" are unambiguous.

### The two identity details, motivated on their own

- Two declarations must not share an id (sibling `case block in f` currently do,
  since `show` drops the `CaseBlock` index). An export whose records silently
  merge is worse than one that fails.
- An id that embeds a source position renames itself when unrelated code moves,
  so a *second* key that erases the position is emitted for cross-run matching.
  This is the same reason a debugger emits both a symbol and a line table.

---

## 2. Runtime path instrumentation (`--dumppathshits`) — the harder sell

### The argument

Every mature toolchain ships execution-count instrumentation: gcov, JaCoCo,
`coverage.py`, `tarpaulin`, `go test -cover`. **Idris 2 has none** — verified:
zero CLI options mentioning instrumentation upstream. Without it there is no way
to know which of the paths from §1 a test suite actually reached, and therefore no
way to build any tooling that reasons about untested code.

Feature §1 gives the denominator and is useless alone for that purpose; this
gives the numerator. But note that §1 stands on its own as an IR-export feature,
so the two must be proposed separately and §1 must not be argued *from* this.

### The design problem that must be solved BEFORE proposing

The fork implements the hook as a `%extern` primitive used by a module in the
**base library** (`System.Coverage`). That makes the tree **unbootstrappable from
scratch**: the checked-in bootstrap Scheme image predates the primitive, so the
stage-1 compiler cannot build a base library that mentions it —
`INTERNAL ERROR: Can't compile unknown external primitive`. An upstream CI that
builds from the checked-in image would fail on the first commit.

This is not a packaging detail; it is the reason this feature is not ready.
Options, roughly in order of how well they'd be received:

1. Emit the hook as a **compiler-inserted call to a runtime support function**
   (the same shape as the existing `libidris2_support` shims), so nothing in base
   references a new primitive and the bootstrap image needs no knowledge of it.
2. Keep the primitive but **regenerate the checked-in bootstrap image** as part of
   the change — heavier, and reviewers dislike opaque regenerated artefacts.
3. Move the module **out of base** into an opt-in package, so the compiler never
   needs the extern to build itself.

Measured, for contrast: a branch carrying only §1 touches no library and
**bootstraps from scratch cleanly** (`bootstrap stage 2 complete`, zero errors).
That is the standard §2 has to meet.

### Objections

- **"Instrumentation changes generated code."** Only under the flag; the default
  path must be byte-identical. That claim needs a test, not a promise.
- **"Which backends?"** A hook that only works on one backend is a maintenance
  liability. Either implement it across the backends the tree supports, or scope
  the proposal explicitly to one and say why.

---

## 3. ES source maps — the one with an owner already

### The argument

Every compiler that emits JavaScript emits source maps: TypeScript,
ClojureScript, PureScript, Scala.js, Kotlin/JS. Without them, a stack trace or a
browser breakpoint in an Idris-generated bundle points at generated code, and the
generated names are mangled. **Idris 2's ES backend emits none** (verified: no
source-map file anywhere upstream).

This is a **debuggability** argument and is completely independent of §1 and §2 —
it is worth having even for someone who never measures anything. Do not bundle it
with the path work; that framing is what made it look like a subsystem rather
than a standard backend feature.

### The specific trap here — verified 2026-08-12

This was already attempted and closed (#3714), and one stated reason was that it
**duplicated a maintainer's existing implementation**. That prior work is real,
and the duplication charge holds up:

- `dunhamsteve/Idris2` (a fork of `idris-lang/Idris2`) carries branches
  **`sourceMaps`** and **`sourceMaps2`**.
- `sourceMaps2` tip `3d3f75177`, **2022-10-17**: 9 ahead / **993 behind**
  upstream, 8 files.
- Its file set overlaps ours in **six** places — `SourceMap.idr`, `Codegen.idr`,
  `Doc.idr`, `Javascript.idr`, `Node.idr`, `idris2api.ipkg` — and one of his
  commits is *"Use compiler directives"*, i.e. even the trigger mechanism
  (a compiler directive rather than a CLI flag) is the same. This reads as the
  same design re-implemented, not an independent arrival.

But it is **not** a finished thing waiting to be adopted, and the plan has to
account for that. Two facts change the shape of the ask:

- **He never proposed it upstream.** The only source-map PRs against
  `idris-lang/Idris2` are #3713 and #3714, both from shogochiai, both closed.
  His branch has sat unproposed since 2022.
- **He says it is unfinished.** The tip commit message: *"Rebased and updated …
  Things seem a little off in the visualizer, so we'll need to debug. Needs tests
  too (somehow)."*
- **He is currently active.** Recent merged upstream PRs include #3775
  (2026-07-28, totality-checking performance), #3799, #3741 — so this is a
  reachable, present maintainer, not an absent one.

So the correct first move is neither "write it again" nor "adopt his branch
wholesale". It is to **ask him**: say the branch was found, name the two gaps he
himself recorded (the visualizer discrepancy and the missing tests), and offer to
do the ~1000-commit rebase and write those tests if he wants it revived. That is
a contribution to his work rather than a third parallel implementation — and a
third implementation, offered while knowing the first two exist, is exactly what
#3714 was closed for.

---

## What this decomposition implies

The three are genuinely independent and land in different places, so the fork
cannot be "finished" into upstream as one thing:

| | stands alone? | blocked by |
|---|---|---|
| §1 paths export | yes — sibling of the existing dump flags | nothing technical; authorship |
| §2 instrumentation | yes — but only after the bootstrap fix | its own design |
| §3 source maps | yes — a standard backend feature | duplicating existing work |

And the downstream tool needs **all three at once**, while upstream would take
them **one at a time, if at all**. That gap is structural, not a scheduling
problem: expect to maintain a fork carrying §2 and §3 even in the best case where
§1 lands.
