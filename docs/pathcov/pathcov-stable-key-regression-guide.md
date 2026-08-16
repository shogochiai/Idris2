# pathcov `stable_key` — regression & integration guide (hot/cold divergence)

Status: 2026-08-11. Author handoff for the luci team's comparison experiment.

The **compiler-side** change ships as one branch — `shogochiai/Idris2 @ pathcov-stable-key`
(tip `b1db7fa67`). It closes the hot/cold path-coverage divergence **at the emitter**,
per `docs/papers/pathcov-id-scheme-design.md`. The **consumer-side** change (magical-utils
+ luci) is described here as instructions to implement + regression-test, not shipped as
branches. A reference implementation exists locally on `idris2-magical-utils @
pathcov-stable-key` and `luci @ pathcov-stable-key` if you want to diff against it.

---

## 0. What the fork branch does (5 commits on `pathcov-stable-key`)

| commit | id | what |
|---|---|---|
| D1a | `2e566fb1f` | duplicate `function_name` with DIFFERING records is a hard error (`InternalError`), not a silent merge |
| tests | `c5864e947` | dumppaths001-004 no longer shell out to `python3` (Idris `PathsExtract.idr` + `awk`) |
| treeRT | `92773b74a` | read the runtime tree so `UserAdmittedPartialGap`/`partial_gap` paths are emitted again |
| D2 | `9b2805c89` | every path record gains a `stable_key` field = `eraseLineCol(function_name) \| branch_label_chain \| ordinal` |
| D1/D4 | `b1db7fa67` | sibling `case block in foo` (and if/then/else, record-update) get a **source-order** suffix `~<k>`, but only when a same-named sibling exists |

`path_id` stays the intra-run **uniqueness** key (position, churns). `stable_key` is the
inter-run **comparison** key: position-erased, so an edit ELSEWHERE in the file leaves it
unchanged, while genuinely different/new paths still differ.

---

## A. Fork regression tests — run these against `pathcov-stable-key`

Build the fork compiler (two-stage; installed fork compiler as boot avoids the
self-overwrite segfault):

```sh
cd Idris2-fork && git checkout pathcov-stable-key
cp src/Compiler/Common.idr ../idrislang-idris2/src/Compiler/Common.idr   # or build in-tree
cd ../idrislang-idris2
nix develop -c make all IDRIS2_BOOT=~/.idris2/bin/idris2 SCHEME=scheme
IDR=$PWD/build/exec/idris2
```

**A1 — dumppaths001-004 pass (no regression, python-free):**
```sh
for t in dumppaths001 dumppaths002 dumppaths003 dumppaths004; do
  cd tests/codegen/$t; rm -rf build; sh run "$IDR" | diff -q expected - && echo "PASS $t"; cd -
done
# expect: PASS x4
```

**A2 — D2 churn invariance (the core property):** a where-local's `path_id` churns when
unrelated declarations move, its `stable_key` does not.
```sh
# Base.idr: `foo m = go m where go Nothing=0; go (Just x)=x`
# Churn.idr: same, with 15 dummy top-level decls inserted ABOVE foo
$IDR --dumppaths-json b.json --check Base.idr
$IDR --dumppaths-json c.json --check Churn.idr
# expect: go's path_id differs (e.g. Main.2629:5:go -> Main.2779:140:go),
#         go's stable_key IDENTICAL (Main.go|Nothing|0 / Main.go|Just|0)
```

**A3 — negative control:** collapsing a clause makes the deleted path's `stable_key` vanish
(the key is not vacuously constant).

**A4 — D1/D4 sibling disambiguation + its churn-stability:** two `case block in foo` in one
function.
```sh
$IDR --dumppaths-json m.json --check TwoCaseBlocks.idr
# expect: stable_keys ...foo~0|True|0 and ...foo~1|True|0 (DISTINCT)
# then insert 15 decls above -> the ~0/~1 are UNCHANGED (source-order ordinal, churn-stable).
# (The raw CaseBlock index churns 16/39 -> 151/174; the ~<k> ordinal does NOT — that is the point.)
```

**A5 — luci baseline no-regression sweep** (the safety proof): run the new compiler over all
`pkgs/Luci/src` modules with `--dumppaths-json ... --check --find-ipkg <mod>` and confirm
against the baseline (`~/.idris2/bin/idris2`, 46a31dc):
- **0** crashes / `InternalError` / `duplicate function_name`
- **0** compile-rc changes
- **0** baseline `path_id`s lost (additive only; some gain `~<k>`)
- `stable_key` present on every path record
- `~<k>` disambiguation fires where real sibling case blocks exist (measured: **109 of 169
  modules**, e.g. BuildFromThread 94 paths, Boundary/Error 70 — these were silently
  under-counted before).

Measured result on this handoff: all five clean.

---

## B. Consumer changes to implement (D3) — magical-utils + luci

The emitter now provides `stable_key`; the consumers must READ it and DELETE the
hand-rolled position-erasure stopgaps (`eraseLineColPrefix`, `normalizePathId`). Per D3 the
comparison key must have ONE definition — the emitter's — never a consumer regex over
`path_id`.

### B1 — idris2-magical-utils (`Idris2CoverageCore`)
1. `PathObligation` (PathCoverage.idr): add `stableKey : String`.
2. `parsePath` (DumppathsJson.idr): `stableKey = fromMaybe pathId (getStringField "stable_key" json)`
   (fallback to `path_id` only for pre-D2 blobs — never reconstruct by regex).
3. The missing-path / unknown-path report lines: append ` :: sk=<stableKey>`.
4. Update the 6 `MkPathObligation` construction sites (parser, Android backend, 4 tests).

### B2 — luci
- `BuildFromThread.idr`: DELETE `eraseLineColPrefix`. `newTIRelativeTo` / `tiPathFunction`
  compare on the emitted `sk=` marker (`stableKeyOfLine` = text after `sk=`; `declOfStableKey`
  = text before the first `|`). Keep a LOCAL position-strip only in `tiPathFunction`'s fallback
  for bare cov.log ids that carry no `sk=`.
- `RedoxImpact.idr`: DELETE `normalizePathId`. `pathFactsOfDumppaths` keys each lineage on the
  emitted `stable_key` (`stableKeysOfDumppaths` = a flat `"stable_key"` scanner, zipped 1:1
  with `pathIdsOfDumppaths`); attribute the specId via the RAW `path_id` (hits carry that).
  Fallback to `path_id` when a blob has no `stable_key`.
- Rewrite tests `REQ_EC_CI_GATE_DIFFSCOPE_ERASELINECOL` and `REQ_EC_REDOX_PATHFACTS_003` to
  drive `sk=` lines / `stable_key` blobs. `REQ_EC_CI_GATE_DIFFSCOPE_DOMAIN` needs no fixture
  change IF you keep the `tiPathFunction` bare-cov.log fallback.

Reference impl commits (local, unpushed): magical-utils `7bd5dffc`, luci `1db2247`.

---

## C. End-to-end comparison experiment (baseline vs new stack)

Build model here: sibling checkouts under one dir; luci `pack.toml` references magical-utils
by `type = "local"` sibling paths and pins the compiler via the `[idris2]` override. To run
the NEW stack, point that override at the new fork commit and check magical-utils out on the
consumer branch:

```toml
# luci/pack.toml — for the experiment only
[idris2]
url = "https://github.com/shogochiai/Idris2"
commit = "b1db7fa67..."   # pathcov-stable-key tip (new) vs 46a31dc... (baseline)
```

Reference verification done on this handoff (direct package-path build, not `pack` — pack was
fragile in this env):
- luci `luci.ipkg` builds (162 modules + executable) against the D3 consumer + new compiler.
- `luci-tests`: the three affected tests PASS (`..._ERASELINECOL`, `..._DOMAIN`,
  `REQ_EC_REDOX_PATHFACTS_003`); overall 1271 passed / 1 failed (the 1 = pre-existing
  `REQ_LIS_CLI_MEMORY_ENCRYPTION_HONESTY_001`, unrelated).
- Real end-to-end: ran luci's REAL `stableKeysOfDumppaths` / `pathFactsOfDumppaths` /
  `newTIRelativeTo` on a real 487-path BuildFromThread blob (94 `~<k>` siblings): no crash,
  **474 distinct lineages, 0 spurious collision**; churn test on live data → `newTIRelativeTo`
  reports **0** false-new.

### Known, pre-existing, NOT a regression
Same-named where-locals in DIFFERENT parent functions (`go`/`needle`/`takeId`) share a
`stable_key` (position erased → same name), so they still merge — an "acceptable, deliberate
under-count" the deleted `normalizePathId` comment already called out. If you want them
distinct too, group `disambiguate` on `eraseLineCol(fullShowName n)` (not `fullShowName n`);
this appends `~<k>` to same-named where-locals as well. Broader `path_id` change — decide
separately.
