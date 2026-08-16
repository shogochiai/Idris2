# Reference: a two-key path identity for `--dumppaths-json`

**Purpose of this document.** A complete, annotated reference of the path-coverage
identity changes, written so you can understand every detail and then **re-implement
it yourself, by hand**. It is a study aid, not a contribution: the upstream policy
requires genuinely human-authored work, so the value here is the *understanding*, not
the text. Read it, argue with it, throw it away, and write your own.

It is de-branded on purpose: the shipped fork code carries project-internal comments
(`Finding E`, `Finding I`, `pathcov-id-scheme-design`, references to a downstream
consumer). Those must be stripped for any upstream framing; below, the feature is
described as a generic compiler concern.

Everything here concerns the exporter in `src/Compiler/Common.idr`. Note up front:
`--dumppaths-json` *itself* is not in upstream Idris2. This document assumes that
exporter exists and only describes the **identity scheme layered on top of it**. If
you are aiming upstream, the exporter is the thing to land first; this is a later
refinement.

---

## 0. The exporter in one paragraph (so the rest has a place to attach)

`--dumppaths-json` walks each function definition's case tree and emits, per
*execution path* (root-to-leaf through the case tree), a JSON record. For a name
`n`, `functionName = fullShowName n`; the paths come from `collectPathResults`, which
recurses the `CaseTree`, and each branch it descends prepends a *step* carrying that
branch's `branch_label` (the constructor / constant / `default` it matched). A leaf
becomes a *terminal* (reached clause, impossible, partial gap…). Each path is then
serialised to `{ "path_id": ..., "classification": ..., "steps": [...] }`. The whole
per-function record is written to a `<out>.parts` line; a finalisation step
concatenates the parts into the final JSON.

Four questions this document answers, in order:

1. What happens when two declarations produce the *same* id? (**collision**)
2. Which case tree do we read — source or runtime? (**partial gaps**)
3. How do you compare a path across two runs when its id encodes source position?
   (**the second key**)
4. How do you keep sibling declarations distinct *without* reintroducing that
   position churn? (**the ordinal**)

---

## 1. A collision must be an error, not a silent merge

**Symptom.** The final JSON is assembled from per-function `.parts` lines, deduped on
the `function_name`. If two *different* declarations serialise to the same
`function_name`, the naive dedup keeps one and drops the other — the denominator
silently loses obligations. Wrong in the direction that looks like success.

**Rule.** Deduping is only safe when the two records are **byte-identical** (the same
function legitimately re-appended by a chunked run). If two records share a name but
*differ*, that is a real collision and the exporter must fail loudly.

```idris
-- returns Right deduped, or Left <name> on a real collision
dedupeFunctionEntries : List String -> Either String (List String)
dedupeFunctionEntries = go SortedMap.empty []
  where
    go : SortedMap String String -> List String -> List String -> Either String (List String)
    go _    acc []             = Right (reverse acc)
    go seen acc (entry :: rest) =
      case extractFunctionNameEntry entry of      -- pull "function_name" out of the JSON line
           Nothing => go seen (entry :: acc) rest -- no name field: pass through
           Just fn => case SortedMap.lookup fn seen of
                           Nothing   => go (SortedMap.insert fn entry seen) (entry :: acc) rest
                           Just prev => if prev == entry
                                           then go seen acc rest          -- identical: benign, drop dup
                                           else Left fn                   -- differ: real collision
```

At the call site, `Left` becomes a hard error:

```idris
parts <- case dedupeFunctionEntries (filter (/= "") (lines existing)) of
              Right ps  => pure ps
              Left dup  => throw $ InternalError $
                "duplicate function_name '" ++ dup ++ "' with differing path records"
```

**Why value-per-line is high:** this converts every future instance of the collision
class from an invisible miscount into a build failure. It is independent of the id
scheme and worth landing on its own. **Consequence to design for:** any downstream that
gated on the exporter succeeding must now handle "the tool errored" (e.g. fall back to
a coarser measurement) — otherwise you have converted a silent undercount into a hard
block. That fallback lives outside the compiler.

**Note the ordering dependency:** this alone makes a *colliding* package fail to
export. §4 is what makes such packages exportable again by giving the colliding
declarations distinct names. So this rule and §4 are two halves of one story.

---

## 2. Read the runtime tree, not the compile-time tree

A `PMDef` carries two case trees: `PMDef pminfo args treeCT treeRT clauses`.

- `treeCT` — the **compile-time** tree: only the user's written clauses.
- `treeRT` — the **runtime** tree: the lowered form, where the compiler has
  materialised the catch-all for a non-exhaustive `partial` function as an
  `Unmatched "Unhandled input…"` default.

A partial-coverage obligation (the missing `Nothing` case of a `partial fromJust`) is
*only* present in `treeRT` — `treeCT` has no node for a clause the user never wrote.
So the exporter must read `treeRT`:

```idris
PMDef _ _ _ treeRT _ =>
  let functionName = ...            -- see §4
  in do treeRTFull   <- full (gamma defs) treeRT
        let (paths, _) = collectPathResults functionName 0 treeRTFull
        ...
```

**Trap.** A "stabilisation" change had flipped this to `treeCT` (because `treeRT` is
absent for some defs), which silently dropped every partial-gap path. If you re-derive
this, guard the choice: the classification machinery (`optimizer_artifact`,
`compiler_partial_completion`) is *built for the lowered tree*, so `treeRT` is the
intended source; handle the "no runtime tree" case explicitly rather than by switching
trees.

**Why not compute gaps from `treeCT` + the datatype's constructor set?** Because
indexed families break a syntactic "which constructors are missing" check: a
`Vect (S (S (S Z)))` scrutinee matched by a single `(a::b::c::[])` clause is
*exhaustive*, and a constructor-count check would wrongly invent a `::`/`[]` gap. The
runtime tree already encodes the compiler's real coverage decision, GADTs included, so
reading it is both simpler and correct. (Verify with a `Vect 3` function: it must get
**no** gap.)

---

## 3. The second key: `stable_key`

### 3.1 The thesis

One `path_id` is asked to do two incompatible jobs:

| job | needs | broken by |
|---|---|---|
| **distinguish** two declarations within one run | source position | — |
| **match** the same obligation across two runs | position-*independence* | source position |

The compiler names nested/local declarations with an encoded position (e.g.
`Mod.2629:5:go`). That makes them unique in a run (good for job 1) but renames them
whenever anything above them moves (fatal for job 2 — a diff of two runs reports
untouched paths as new). These are **two keys, not a trade-off**. Emit both:

- `path_id` — the intra-run **uniqueness** key. Keep it exactly as is (position and
  all). It is allowed to churn.
- `stable_key` — the inter-run **comparison** key. Position erased.

### 3.2 Erasing the position

The encoded position is a run of `<digits>:<digits>:`. Erase every such run from the
name, keeping the nesting shape:

```idris
eraseLineCol : String -> String
eraseLineCol s = pack (go (unpack s))
  where
    isDigitChar : Char -> Bool
    isDigitChar c = c >= '0' && c <= '9'
    -- a position run is digits ':' digits ':'; return the tail after it, or Nothing
    dropLineColRun : List Char -> Maybe (List Char)
    dropLineColRun cs =
      let (d1, rest1) = span isDigitChar cs in
      case (d1, rest1) of
        ([], _)             => Nothing
        (_, ':' :: rest1')  =>
          let (d2, rest2) = span isDigitChar rest1' in
          case (d2, rest2) of
            ([], _)            => Nothing
            (_, ':' :: rest2') => Just rest2'
            _                  => Nothing
        _ => Nothing
    go : List Char -> List Char
    go []             = []
    go cs@(c :: rest) =
      if isDigitChar c
        then case dropLineColRun cs of
               Just after => go after       -- drop the whole run
               Nothing    => c :: go rest    -- a lone digit, keep it
        else c :: go rest
```

`Mod.2629:5:go` → `Mod.go`; `Mod.topLevel` (no run) → unchanged.

**This function is the single definition of position-erasure.** A downstream that
re-derives it by its own regex over `path_id` will drift silently the day the id
format changes (a matcher that stops matching looks exactly like "nothing moved").
That is why the key is *emitted*.

### 3.3 The key itself

```
stable_key = eraseLineCol(function_name) | branch_label_chain | ordinal
```

- **declaration** — `eraseLineCol(function_name)`: module + nesting shape, position
  gone.
- **branch_label_chain** — the sequence of `branch_label`s along the path
  (`"::" , "\"setimpl\"" , …`). This is the component that gives the key *meaning*: it
  is what a test must actually drive. To have it available at emit time, carry it on
  the path record alongside the already-serialised steps:

  ```idris
  record PathResult where
    constructor MkPathResult
    terminal : PathTerminal
    steps    : List String   -- serialised step JSON (unchanged)
    labels   : List String   -- NEW: the branch_label chain, root->leaf

  -- prependStep already runs once per descended branch; also cons the label:
  prependStep fn ci bi branchLabel origin span (MkPathResult t steps labels) =
    MkPathResult t (stepJson fn ci bi branchLabel origin span :: steps)
                   (branchLabel :: labels)
  -- a leaf starts empty: MkPathResult (terminalFor leaf) [] []
  ```

- **ordinal** — disambiguates *genuinely identical* siblings (same declaration shape,
  same labels); see §4. Computed per record.

```idris
joinLabels : List String -> String
joinLabels []        = "-"
joinLabels [x]       = x
joinLabels (x :: xs) = x ++ "," ++ joinLabels xs

stableKey : String -> List String -> Nat -> String
stableKey functionName labels ordinal =
  eraseLineCol functionName ++ "|" ++ joinLabels labels ++ "|" ++ show ordinal
```

Emit it as a field next to `path_id`. It is purely additive — nothing that reads the
other fields changes.

---

## 4. Keeping siblings distinct without reintroducing churn

### 4.1 The collision that §1 makes loud

Anonymous case blocks are named `case block in <fn>` with the disambiguating index
**dropped by `show`** (`show (CaseBlock outer i) = "case block in " ++ outer`). So two
`case`/`if-then-else`/record-update blocks in one function share one `function_name` —
and now share one `stable_key` too. §1 turns this into a build error; this section makes
the ids distinct so the export succeeds *and* the two siblings count separately.

### 4.2 The approach that does NOT work — splice the structural index back in

The obvious fix is to put the `CaseBlock`'s `i` back into the name. **It regresses**,
and the reason is the whole point of the design: **`i` is a global counter and it
churns.** Measured — two siblings get indices `16` and `39`; insert 15 unrelated
declarations above them and they become `151` and `174`. A `stable_key` built on `i`
would therefore churn on unrelated edits — exactly the failure `stable_key` exists to
prevent. Do not use the structural index.

What *is* stable is the siblings' **relative source order**: `16 < 39` and
`151 < 174`. The order is invariant under edits elsewhere even though the absolute
indices are not.

### 4.3 The fix — a source-order ordinal, only where a sibling exists

Append `~<k>` to a name, where `k` counts same-named declarations emitted *before* this
one. Do it only when a same-named sibling actually exists, so unique names (top-level
functions, where-locals, singleton case blocks) are untouched — no existing id changes.

```idris
disambiguate : List Name -> List String
disambiguate ns =
  let names  = map fullShowName ns
      counts = foldl (\m, s => SortedMap.insert s (S (maybe 0 id (SortedMap.lookup s m))) m)
                     SortedMap.empty names                 -- total count per name
  in reverse (snd (foldl (step counts) (SortedMap.empty, []) names))
  where
    step : SortedMap String Nat -> (SortedMap String Nat, List String) -> String ->
           (SortedMap String Nat, List String)
    step counts (seen, acc) nm =
      let k     = maybe 0 id (SortedMap.lookup nm seen)     -- running index
          seen' = SortedMap.insert nm (S k) seen
          disp  = if maybe False (> 1) (SortedMap.lookup nm counts)
                     then nm ++ "~" ++ show k               -- has a sibling: disambiguate
                     else nm                                -- unique: leave alone
      in (seen', disp :: acc)
```

Thread the disambiguated name in place of `fullShowName n` at every place that
iterates a name list and emits records — there is more than one such caller; miss one
and that path re-collides. Then `functionName = <the disambiguated name>` feeds both
`path_id` and `stableKey`.

**Why it composes with §3:** `eraseLineCol` strips `<digits>:<digits>:` runs, **not**
`~<k>`. So `~0`/`~1` survive into the `stable_key` (siblings distinct) while the
position component is still erased (churn-free). Two properties at once, from one
suffix.

**Verification that pins it:** two sibling case blocks →
`…foo~0|True|0` and `…foo~1|True|0` (distinct). Insert 15 unrelated declarations
above → the `~0`/`~1` are **unchanged** (relative order held). A where-local's
`stable_key` is still invariant across the same edit. Existing exporter tests are
unchanged (no singleton name gains a suffix).

### 4.4 Honest limits — state them, do not hide them

- **Reordering** two identical siblings swaps their ordinals. That is *correct*: the
  key is meant to be sensitive to edits *within* a declaration's context and
  insensitive to edits *elsewhere*. An id should change when its code moves relative
  to its true siblings, and only then.
- **Chunked export.** The ordinal is computed over one name list. If the exporter ever
  processes a module's names across *separate* calls, each call restarts the count;
  the group must be whole. Not observed to bite, but it is a real precondition —
  assert it or document it.
- **Same-named where-locals in different parent functions** (`go` in three functions)
  share a `stable_key` after erasure (same name, same labels) and still merge. This is
  a pre-existing, deliberate under-count. If you want them distinct too, group
  `disambiguate` on `eraseLineCol(fullShowName n)` rather than `fullShowName n`; that
  also suffixes same-named where-locals. It touches many more ids — a separate
  decision, not a bug fix.

---

## 5. How to prove it (the test matrix worth re-deriving)

1. **Churn invariance.** A where-local: unrelated insertion above → `path_id` changes,
   `stable_key` identical.
2. **Negative control.** Delete a clause → the removed path's `stable_key` *disappears*.
   (Guards against an accidentally-constant key that would pass test 1 vacuously.)
3. **Sibling distinctness + stability.** Two case blocks → distinct `~0`/`~1` keys,
   unchanged after an unrelated insertion.
4. **Indexed-type gap.** A total `Vect 3` one-clause function → **no** partial gap.
5. **No-regression sweep.** Run the new exporter over a large real corpus and diff
   against the old: zero crashes, zero collisions-as-error where none should fire, zero
   ids *lost* (only additive `~k` and the new field), `stable_key` present everywhere.

Tests 2 and 3-under-insertion are the ones people skip and the ones that catch a
vacuous or churning key.

---

## 6. What is upstream-shaped, and what is not

- Landable in principle, human-written, RFC-first: **`--dumppaths-json` itself** (a
  read-only exporter that changes no default output). That is the lead.
- The two-key scheme here is a *refinement layer* on that exporter. It only makes sense
  once the exporter exists upstream. Sequence accordingly.
- Strip every project-internal reference (`Finding E/I`, downstream tool names, the
  design-doc name) before any upstream framing. The mechanism stands on its own; the
  provenance vocabulary does not.
