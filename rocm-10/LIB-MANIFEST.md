# LIBRARY MANIFEST — which binary proves which claim

> Paths below are labels, not a filesystem layout: absolute prefixes from the machine this
> ran on have been removed. `lib-*` names a build output directory, `src-*` names a source
> tree, and run-dir names identify a measurement window. Library sha256 values are the
> identifiers that matter and are unmodified.
Every ROCm 10 HIP library built or tested in this work, with the source tree that produced it, the
patch it carries, its content hash, and the reproducer artifact it generated. Written because both
of our builds share the same soname (`libamdhip64.so.7.15.26333-6b0e43f341`, from `therock-10.0`),
so soname alone cannot tell them apart — content hash, byte size and embedded strings can.

Base source for all local builds: `github.com/ROCm/rocm-systems` tag `therock-10.0` =
`6b0e43f341195e203754e08f850e437ff2fc09f9`, cross-checked against the installed stack's own
`AMDSMI 27.0.0+6b0e43f3`.

| id | library path | sha256 (16) | bytes | source tree | patch carried | discriminating string |
|---|---|---|---|---|---|---|
| **A** | `<rocm-10.0 prefix>/lib/libamdhip64.so.7` | (as shipped) | — | AMD release | none | soname suffix `-0000000` |
| **B** | `lib-pr10022-only/` | `e7a591f6b7ecd8ea` | 94,730,144 | `src-pr10022` | **PR #10022 exact bytes**, 3 files / 25 insertions | `Failed to allocate fill constant buffer (out of memory)` = 1, ours = 0 |
| **C** | `lib-rocm-10.0-fix1-fix2b/` | `7a42ee09f9084eaf` | 94,746,096 | `src` | **our port**, `rocm10-fix1-fix2b.patch` (sha `423aa161c8003bfb`), 4 files / 43 insertions | `batchMemOps: failed to allocate the parameter buffer` = 1, theirs = 0 |
| — | `lib-develop-stock/` | **never produced** | — | `src-develop` @ `e92445f7` | none (pristine develop) | build fails: `HSA_AMD_SYSTEM_INFO_HOST_ALLOC_DMA_BUF_SUPPORTED` absent from 10.0.0 HSA headers |

Tree/library correspondence verified after separating the trees:

```
src          batchMemOps guard = 1   their-wording guard = 0   -> produced C
src-pr10022  batchMemOps guard = 0   their-wording guard = 2   -> produced B
```

## Reproducer results, by library id

Instrument: `residual_repro --iters 262144 --report 40000`, gfx1100, 294 W.
Run dir: `rocm10-sufficiency-20260828/`.

**One canonical row per arm. Each row is self-contained: prefix, library path, soname, sha256,
source tree, patches, rc. Nothing here may be summarised into a combined row.**

| id | prefix (runtime) | library actually loaded | soname | sha256 (16) | source tree | #10022 | fix2b | batchMemOps | rc | outcome |
|---|---|---|---|---|---|---|---|---|---|---|
| **A** | 10.0.0 | AMD's shipped lib, no preload | `7.15.26333-0000000` | `4ac6ac420d354e27` | — (AMD binary) | no | no | no | **139** | `Segmentation fault`, offset `611c42` |
| **F** | **10.1.0 nightly 20260827** | AMD's shipped lib, no preload | `7.16.26342-0000000` | `5208c80d6b66fde8` | — (AMD binary) | no | no | no | **139** | `Segmentation fault`, offset `61a6f2` |
| **F2** | **10.1.0 nightly 20260827** | AMD's shipped lib, no preload; **reproducer rebuilt with 10.1 toolchain** (`3f153e72c860e71e`) | `7.16.26342-0000000` | `5208c80d6b66fde8` | — (AMD binary) | no | no | no | **139** | `Segmentation fault`, **same offset `61a6f2`** |
| **E2** | 10.0.0 | `lib-fix2b-only/` — proven from `/proc/<pid>/maps` | `7.15.26333-6b0e43f341` | `4a337253bf1aa8be` | `src-fix2b-only` (worktree) | no | **yes** | no | **139** | `Segmentation fault` after `round 80000 ok` |
| **B** | 10.0.0 | `lib-pr10022-only/` | `7.15.26333-6b0e43f341` | `e7a591f6b7ecd8ea` | `src-pr10022` | **yes** | no | no | **3** | `STALE-PACKET round 83107: kernel wrote 83106, expected 83107 (silent corruption)` |
| **D** | 10.0.0 | `lib-pr10022-plus-fix2b/` | `7.15.26333-6b0e43f341` | `93d266a3e006bba9` | `src-isolation` | **yes** | **yes** | no | **1** | `STOP round 83107 … (910), updateResult=1, errorNode` set |
| **C** | 10.0.0 | `lib-rocm-10.0-fix1-fix2b/` | `7.15.26333-6b0e43f341` | `7a42ee09f9084eaf` | `src` | re-derived | **yes** | **yes** | **1** | `STOP round 83107 …` |

Attribution notes that keep these rows from collapsing into one another:
- **A vs F/F2 are different runtimes**, distinguishable by soname alone (`7.15.26333-0000000` vs `7.16.26342-0000000`). F/F2 carry **no patch of ours whatsoever** and needed no build of ours.
- **B, C, D, E2 all share the soname `7.15.26333-6b0e43f341`** because all four are built from `therock-10.0`. They are separated by library path, sha256, and disjoint embedded strings — and for E2 additionally by `/proc/<pid>/maps` read from the live process.
- **E2 is the corrected rerun.** The first E attempt is void (empty `LD_PRELOAD`, see the invalidated-run section); its number must never be cited.

## Labelling precision — read this before citing arm C

Arm C is **our port**, not "their patch plus ours". Our port independently re-derives #10022's
guards with our own wording (which is why C contains none of #10022's strings) and adds two things
#10022 does not have: the `batchMemOps` guard, and the `hipGraphExecUpdate` status propagation
(our PR #10714). So C's delta over B is *both* our fix2b and the third guard site.

**Consequence for any public claim:** B → C demonstrates, **in the reproducer**, that #10022 alone
leaves a silent wrong result and that adding our changes surfaces it. **The isolation has since
been measured** — see arm D — so fix2b can be credited on its own.

**Scope limit.** The silent result is a reproducer observation only. The real-workload evidence on
stock 10.0.0 is a *crash* (`llama-server`, 217k ctx, depth 215,482), because production carries no
#10022 and faults before reaching the stale-packet path. An explicit end-to-end test
(`rocm10-endgap-20260828/`, 2026-08-28) returned a **NULL RESULT**: 20,000 forced greedy tokens per
arm, determinism control passed (D1≡D2, B1≡B2, and D1≡B1 all byte-identical), but **zero**
`CUDA graph update failed` detector hits in the fix2b arms — the kernarg pool never exhausted at
20k graph updates against the ~83k the reproducer requires. **That null is absence of the trigger,
not evidence that the stale-packet path is absent.** Do not cite it as disproof, and do not restate
B's result as general runtime behaviour.

## Arm D — the isolation build (added 2026-08-28)

| id | library path | sha256 (16) | bytes | source tree | patch carried | discriminating string |
|---|---|---|---|---|---|---|
| **D** | `lib-pr10022-plus-fix2b/` | `93d266a3e006bba9` | 94,738,200 | `src-isolation` | **#10022 + our fix2b hunk only**, 4 files / 30 insertions, **no `batchMemOps` guard** | #10022 wording = 1, our `batchMemOps` string = **0** |

Result: **`rc=1`**, `STOP round 83107: hipGraphExecUpdate -> … (910), updateResult=1
errorNode=0x57d4afbd7300`. Identical outcome to arm C, from a library that provably lacks the
`batchMemOps` guard. **Therefore the surfaced error is attributable to fix2b (PR #10714) alone**,
and arm D additionally shows the API contract a caller needs: error `910` with `errorNode`
populated. Artifact: `rocm10-sufficiency-20260828/repro-D-pr10022-plus-fix2b.out`.

## Provenance is patch-determined, not tree-determined (verified)

The `-B` build directories all live outside the source trees, and an audit found **0** build
artifacts inside `src`, `src-pr10022`, `src-isolation` and `src-develop`; each tree's working state
contains exactly its intended modified files and nothing else; the object stores are independent
(315 MB each, not shared).

The decisive check, because two of those trees were created with `cp -a` and a copy could in
principle carry something stale:

```
git -C src worktree add --detach wt-verify 6b0e43f341    # fresh checkout, shares objects, no copy
git -C wt-verify apply rocm10-fix1-fix2b.patch           # 4 files changed, 43 insertions(+)
git hash-object <each of the 4 files>  in wt-verify  vs  src
  -> identical: 4/4   differing: 0
```

So **base commit `6b0e43f341` plus the stored patch reproduces the exact source content**, proven
by `git hash-object` rather than by trusting the copy. The trees are a convenience; the patches and
these library content hashes are the evidence. If every tree were deleted, every library here
remains reproducible.

## Arms E and F — kept deliberately separate (added 2026-08-28)

Different **prefixes**, not just different preloads, answering different questions. Never merge
them into one row.

### Arm F / F2 — AMD's latest SHIPPED code, zero patches
*Does AMD's newest released runtime still fault with nothing from us?*

| field | value |
|---|---|
| prefix | `<rocm-10.1-nightly prefix>` |
| origin | `nightly.repo.amd.com/rocm/core/tarball/therock-dist-linux-gfx110X-all-10.1.0a20260827.tar.gz`, 2,601,235,266 B |
| version | **`10.1.0`**, HIP **`libamdhip64.so.7.16.26342-0000000`** (10.0.0 ships `7.15.26333`) |
| patches | **none.** No `LD_PRELOAD`; `LD_LIBRARY_PATH` = the nightly prefix only |
| kernarg-guard strings in their binary | **0** |
| **F** (reproducer built on 7.14) | **`rc=139`**, kernel: `segfault at 0 … error 6 in libamdhip64.so.7.16.26342-0000000[61a6f2]` |
| **F2** (reproducer **rebuilt with the 10.1 toolchain**, sha `3f153e72c860e71e`, linked to their lib) | **`rc=139`**, kernel: same soname, **same offset `61a6f2`** |
| artifacts | `repro-F-amd-10.1-nightly.out`, `repro-F2-native101.out` |

**This upgrades "present in their source" to "faults in their shipped binary."** Everything before
this was code inspection, because develop-tip clr does not build against the 10.0.0 prefix. Arm F
needed no build of ours at all.

### Arm E / E2 — our fix2b alone, no #10022
*Is #10022 actually necessary, or would our patch alone have sufficed?*

| field | value |
|---|---|
| library | `lib-fix2b-only/`, sha256 `4a337253bf1aa8be`, 94,735,448 B |
| source | `src-fix2b-only`, a fresh detached **worktree** at `6b0e43f341`, 1 file / 5 insertions |
| patches | our fix2b **only**; `#10022` strings = **0** |
| **E2** loaded library, proven from `/proc/<pid>/maps` mid-run | `lib-fix2b-only/libamdhip64.so.7.15.26333-6b0e43f341` |
| result | **`rc=139`** after `round 80000 ok` |
| artifacts | `repro-E-fix2b-only.out`, `repro-E2-fix2b-only.out` |

**Conclusion: #10022 is necessary.** The NULL write occurs inside the capture path before any
status is returned, so a caller-side status check cannot prevent it. With arm B, neither patch
alone suffices.

### The complete necessity matrix

| arm | runtime | #10022 | our fix2b | rc | outcome |
|---|---|---|---|---|---|
| A | 10.0.0 stock | no | no | 139 | segfault |
| **F / F2** | **10.1 nightly stock (AMD latest)** | no | no | **139** | **segfault** |
| E / E2 | 10.0.0 | no | **yes** | 139 | segfault |
| B | 10.0.0 | **yes** | no | 3 | no crash, **silent wrong result** |
| D | 10.0.0 | **yes** | **yes** | 1 | clean `910` + `errorNode` |

### Three challenge passes on arms E and F
- **METHOD.** The stale-binary objection (reproducer compiled on 7.14, runtime 7.16) was attacked twice: behaviourally, the run completes baseline capture, instantiation, VRAM exhaustion and 80,000+ successful update rounds before faulting — ABI drift fails at init, not there; and by construction, F2 rebuilt the reproducer with AMD's 10.1 toolchain and faulted at the **identical offset**. A differently-compiled client faulting at the same address inside their library locates the fault in their code.
- **CONFIG.** Arm F carries no `LD_PRELOAD` at all and the kernel names AMD's own soname, which appears nowhere else here. Arm E's soname is shared with arms C and D, so it is instead pinned by `/proc/<pid>/maps` read from the live process, plus library sha and `#10022`-string count.
- **DATA / CURRENCY.** `10.1.0a20260828` returns HTTP 404, so `20260827` is AMD's newest published nightly — tested the same day. Fault signatures are consistent across every arm: `segfault at 0`, `error 6`, per-build offsets `611c42` (stock 10.0.0), `661e5b` (our 10.0 build), `61a6f2` (AMD 10.1).

### Invalidated run — recorded so the number is never reused
The **first** arm E attempt returned `rc=139` and was **invalid**. A `sed` without `/g` renamed only
the `mkdir` target and not the `cp` target, so the library landed in arm D's directory and
`lib-fix2b-only/` was empty; `$L` expanded to nothing, `LD_PRELOAD=` was empty, and the run
silently exercised **stock 10.0.0**. It also overwrote arm D's library. Both were restored from
their intact build directories and re-verified by hash and embedded strings. Arm D's `rc=1`
predates the overwrite and is unaffected. **Lesson: an empty `LD_PRELOAD` fails open and is
indistinguishable from a stock run by rc alone — assert the library resolves, ideally from
`/proc/<pid>/maps`, before trusting any result.**

## Hazard that prompted this file

Both builds were originally produced from one shared tree by reverting and re-patching. After the
#10022 build, `src` held #10022 — so re-running the port build there would have silently produced
a mislabelled library. Trees are now permanently separated (`src` = ours, `src-pr10022` = theirs,
`src-develop` = pristine develop) and each is verified against the library it produced.
Reproducibility does not depend on the trees surviving: base commit plus the stored patch files
regenerate either source state exactly.

## Run ledger — every artifact on disk (2026-08-28)

Run dirs: `rocm10-sufficiency-20260828/` (S),
`rocm10-determinism-20260828/` (T), `rocm10-endgap-20260828/` (E).

| artifact | dir | arm | sha256 (16) | rc evidence |
|---|---|---|---|---|
| `repro-A-stock-10.0.0.out` | S | A | `24db6e52eaf789ff` | in-file footer `exit_code: 139` + kernel line |
| `repro-B-pr10022-only.out` | S | B | `6f6eb73cdaca1cb3` | in-file `STALE-PACKET round 83107` (value check, not rc) |
| `repro-C-pr10022-plus-ours.out` | S | C | `45cd29e14567b4ec` | in-file `STOP round 83107` |
| `repro-D-pr10022-plus-fix2b.out` | S | D | `843d24a9c7d671f7` | in-file `STOP round 83107 … (910)` |
| `repro-E-fix2b-only.out` | S | **VOID** | `4a2c013d720d6fc2` | **do not cite** — see marker below |
| `repro-E2-fix2b-only.out` | S | E2 | `2e57062e3ae81524` | in-file footer `exit_code: 139` + kernel line |
| `repro-F-amd-10.1-nightly.out` | S | F | `54654a35c7ede913` | in-file footer `exit_code: 139` + kernel line |
| `repro-F2-native101.out` | S | F2 | `645b76ad880d746f` | in-file footer `exit_code: 139` + kernel line |

**Repeat counts, by directory — so the ratios in the prose can be traced.**

| arm | S | T | total | every run identical? |
|---|---|---|---|---|
| B (#10022 only) | 1 | 3 (`B-run1..3`) | **4** | yes — `STALE-PACKET round 83107` in all four |
| D (#10022+fix2b) | 1 | 2 (`D-run1..2`) | **3** | yes — `STOP round 83107` in all three |
| E2 (fix2b only) | 1 | 2 (`E2-run1..2`) | **3** | yes — segfault after `round 80000 ok` |
| **A** (stock 10.0.0) | 1 | — | **4** | yes — see the four dirs below; this is the "4/4" quoted in `README.md` |
| F / F2 (10.1 nightly) | 1 each | — | 1 each | **2/2** across the pair; F additionally re-reproduced 2026-08-28 03:06 |

**Arm A's four runs are spread across four run dirs, not S alone** — the "4/4" in the claim
boundary traces to these files, each ending in a stock-soname segfault:

| # | file |
|---|---|
| 1 | `rocm10-bugcheck-20260827/repro-rocm10-stock.out` |
| 2 | `rocm10-hybrid-20260827/repro-rocm10-stock-again.out` |
| 3 | `rocm10-ported-20260828/repro-stock-10.out` |
| 4 | `rocm10-sufficiency-20260828/repro-A-stock-10.0.0.out` (in-file `exit_code: 139`) |

A fifth stock reproduction was run 2026-08-28 03:06 and overwrote (4); it reproduced the same
outcome and added the in-file provenance footer. `dmesg` independently retains stock-soname
(`…-0000000`) segfault records from these runs.

**Ratio convention.** Every ratio quoted anywhere in this package counts **all runs of one named
arm across every run dir** — B is 4/4, not 3/3 counting only the determinism dir. Ratios are never
pooled across arms. B's fourth run is in S, not T; A's four are in four different dirs, listed
above. The determinism table in `FAULT-CHAINS.md` uses this same scale.

### Disclosure: four artifacts were regenerated on 2026-08-28
`repro-A-…`, `repro-E2-…`, `repro-F-…` and `repro-F2-…` were **re-run**, overwriting the earlier
files, because the originals recorded only the program's stdout: the `Segmentation fault` notice is
emitted by the **shell**, not the process, so those artifacts did not self-evidence their own
result. The re-runs write a provenance footer **during the run** (`exit_code`, resolved library,
`lib_sha256`, and any new kernel `segfault` line). Every re-run reproduced the original outcome
(`rc=139`). Consequence: their mtimes are later than the rest, and the earlier bytes no longer
exist. The footers are harness-written, not hand-edited.

### The void artifact is deliberately left byte-untouched
`repro-E-fix2b-only.out` (`4a2c013d720d6fc2`, mtime 01:24) is **not** annotated in place — editing
a captured run would make it neither the run's output nor a clean document. Its invalidity is
recorded here and in a sibling file, `repro-E-fix2b-only.VOID.txt`, so a reader browsing the
directory cannot miss it. See "Invalidated run" above for the cause.

### Patch statistics: `git` is canonical
**Canonical sources, in order:** `git apply --stat`, and the `format-patch` diffstat embedded in
the patch file itself. Every insertion/file count in these documents comes from those and agrees
with them.

| patch | canonical stat |
|---|---|
| `rocm10-fix1-fix2b.patch` | **4 files changed, 43 insertions(+)**, 0 deletions |
| `pr10714-rebased-develop.patch` | **1 file changed, 10 insertions(+)** — also carried inside the file's own `format-patch` diffstat. This is the guard hunk extracted from PR #10714, not the whole PR (3 files, +159, including a 147-line regression test). |
| #10022's clr hunks (arm B) | 3 files, 25 insertions |
| isolation subset (arm D) | 4 files, 30 insertions |
| fix2b-only (arm E2) | 1 file, 5 insertions |

**There is no discrepancy in the patch statistics.** Noted only as a transient audit artifact: on
2026-08-28 an ad-hoc shell line-count produced a figure that disagreed with `git`. **Line-counting
`+`-prefixed rows is not a diffstat and is explicitly non-authoritative in this package** — it was
never a source for any figure here, and no figure changed. The specific wrong value is omitted
deliberately: it is bound to nothing, nothing depends on it, and it was not investigated to a
conclusion. If a transcript shows a count that differs from the table above, the table governs.

**Rule: re-derive patch statistics with `git apply --stat` (or read the `format-patch` diffstat
embedded in the patch), never by counting `+`-prefixed lines.** A patch file contains `+` at the
start of lines for reasons other than additions — diff headers among them — so a line count is not
a diffstat.

**The same class of error recurred in the audit tooling itself.** A verification script written to
confirm each arm's `rc` reported three arms as failing. The documents were correct; the *script*
was wrong — its pattern matched an arm row in a different table on this page, and it compared
against that. Resolved by extracting the rc column positionally from the canonical table and
printing every row for inspection. **Rule: when a check disagrees with a document, verify the
check before amending the document** — and prefer a check that prints what it matched over one
that prints only a verdict.
