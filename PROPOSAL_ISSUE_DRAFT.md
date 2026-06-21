# Proposal: machine-readable export of canonical path obligations for external tooling

Draft for an idris-lang/Idris2 issue, to be filed before the compiler PRs
(`--dumppaths-json`, `--dumppathshits`). Fork-only file; not part of any PR.

---

**Title:** Machine-readable export of canonical case-tree paths (`--dumppaths-json`)

**Summary**

I'd like to add a compiler flag that exports the canonical intrafunction paths
Idris2 already computes from elaborated case trees, as structured JSON. The goal
is to give external tooling a stable, backend-independent *denominator* for
path-level analysis — most concretely, semantic test-obligation coverage that is
aware of dependent-type reachability rather than raw line coverage.

Idris2 is unusually well suited to this: because totality is a first-class,
enforceable property and unreachable branches can be discharged with
`impossible`, the compiler's own notion of "which paths exist and which are
reachable" is far more meaningful than a line/branch counter bolted on after the
fact. Today that information lives only inside the compiler. Exporting it lets
coverage and analysis tools consume the *compiler's* truth instead of
re-deriving an approximation.

**Proposed surface**

- `--dumppaths-json <file>`: write each function's per-clause branch paths, with
  path id, reachability classification, terminal kind, and source span, as JSON.
  Adds a new flag only; default compilation output is unchanged byte-for-byte.

**Why upstream rather than a plugin**

The path set is derived from the elaborated case tree, which is internal. A flag
is the smallest stable contract; without it, every downstream tool must fork the
compiler (which is exactly the situation I'm trying to retire).

**Optional follow-ups (separate PRs, only if there's appetite)**

- `--dumppathshits <file>`: opt-in runtime instrumentation that records which
  paths actually execute (the *numerator*). Default-off; uninstrumented builds
  are unchanged. On Chez it writes path ids to a file; on JS it emits a no-op
  hook unless a global handler is installed.

**Scope I am NOT proposing**

- No change to coverage/totality checking itself.
- No new always-on output; everything is behind explicit flags.
- The "partial gap" obligation (paths for *missing* cases of a `partial`
  function) is intentionally out of scope for the initial export — the current
  implementation emits only paths that correspond to written clauses.

**Status**

I have a working implementation rebased onto current `main`, self-building with
tests, that I can open as a focused PR (compiler changes ~14 files, behind the
new flag, plus two codegen tests). Happy to adjust the JSON shape or flag name
to whatever the maintainers prefer before sending it.

Would a PR along these lines be welcome?
