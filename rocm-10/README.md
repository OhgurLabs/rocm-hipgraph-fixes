# ROCm 10 — both defects still ship (2026-08-28)

ROCm 10.0.0 was released 2026-08-26. Both members of this defect family are still present in it,
and in AMD's newest published nightly at the time of writing (10.1.0 `20260827`). This directory
carries the patches ported to the 10.0 source, the rebased upstream PR, and the evidence.

Hardware for everything here: one Radeon RX 7900 XTX (gfx1100) at a 294 W cap, Linux 7.0.14-14-pve.

## Neither fix is sufficient alone

Each arm below is a separately built `libamdhip64`, bound to a content hash, with the loaded
library read back from `/proc/<pid>/maps` so no arm can be mistaken for another. Full table with
sha256s in [`LIB-MANIFEST.md`](LIB-MANIFEST.md).

| runtime | #10022 | our fix | rc | outcome |
|---|---|---|---|---|
| 10.0.0 as shipped | no | no | 139 | `SIGSEGV`, offset `611c42`, kernel-attributed to soname `…-0000000` |
| 10.1.0 nightly `20260827`, as shipped | no | no | 139 | `SIGSEGV`, offset `61a6f2` |
| 10.0.0 | no | yes | 139 | `SIGSEGV` — the NULL write precedes any status return |
| 10.0.0 | yes | no | 3 | no crash, **silent wrong result**: `kernel wrote 83106, expected 83107` |
| 10.0.0 | yes | yes | 1 | `hipErrorGraphExecUpdateFailure` (910) with `errorNode` populated |

The 10.1-nightly row was also run with the reproducer recompiled using AMD's 10.1 toolchain. It
faulted at the same offset. The fault address did not move with the client's compiler on that pair
of runs, which is evidence against a client-side ABI mismatch rather than a formal exclusion.

## Upstream status

- **Crash** — ROCm/rocm-systems issue #10021, fix PR **#10022** by `nycdubliner`. **Not our work.**
- **Dropped status** — our PR **#10714**: 3 files, +159. The guard itself is 11 lines in
  `hip_graph.cpp`; the remainder is a 147-line regression test
  (`hipGraphExecUpdate_error_propagation_test.cc`) and its CMakeLists entry.

Both were open and unmerged, and both defects were present in the source, when last checked at
`develop` tip `97ab4d1f880b1814f736de11453b525bed21a250` (2026-08-28T02:34Z). They were
also present at the earlier tip `e92445f708bfd09d679363144948fa60af6bebdc` (2026-08-27T23:39Z); the
three commits between those tips touch none of the four files involved. See [`PRIOR-ART-SWEEP.md`](PRIOR-ART-SWEEP.md) for how that was established.

## What the ten-line fix does

`hipGraphExecUpdate` calls `UpdateAQLPacket`, assigns its status, and never reads it. A recapture
that failed reports success, and the next launch replays the previously captured packet.

There are ten `UpdateAQLPacket` call sites in `hip_graph.cpp`. Nine propagate the status. The one
inside `hipGraphExecUpdate` is the only one that drops it, and that is the site the patch guards.
The change makes that site match the convention already used at the other nine.

AMD's own `hip_runtime_api.h` documents `hipGraphExecUpdate` as returning `hipSuccess` or
`hipErrorGraphExecUpdateFailure`, with `updateResult_out` reporting whether the update was
performed and `hErrorNode_out` naming the node that forbade it. Returning success while the status
is dropped violates that documented contract, independently of memory pressure.

## Porting notes

The 7.14 diffs in the repo root do **not** apply to 10.0. Segment scheduling is gone, so the guard
condition becomes `GraphCaptureEnabled()`. The capture loop gained a second packet vector that must
be cleared on the error path or the two go index-desynchronised. `constBuf` was renamed
`kernArgBase` in one of three sites, and 10.0 has a third unguarded `rocblit` site the 7.14 patch
never covered. `port-fixes-to-10.py` applies the port by unique anchor and aborts unless every
anchor matches exactly once.

## Scope — what this evidence does and does not show

- The **crash** is observed on stock 10.0.0 and on 10.1 nightly, kernel-attributed by soname.
- A real long-context `llama-server` workload (27B Q4_K_XL, 217k context) also segfaulted on stock
  10.0.0, at depth 215,482. No reproducer involved.
- The **silent wrong result is a reproducer observation only.** It has not been seen end to end in
  a real server. An explicit test was run and returned a null: across 20,000 forced greedy tokens
  the kernarg pool never exhausted, and the reproducer needs roughly 83,000 graph updates to reach
  the trigger. That is absence of the trigger, **not** evidence that the path is unreachable, and
  it must not be cited as disproof.
- `batchMemOps` carries the same unguarded pattern on a capture-reachable path and is not covered
  by #10022. This is a code-inspection finding; **it has never been faulted here.**
- AMD's released libraries are stripped, so their faulting offsets are reported as *consistent
  with* `submitKernelInternal`. The symbol-level proof comes from our own debug build only.
- "No fix reachable in `rocm-systems`" is bounded to refs reachable there. A fix on a private
  branch would be invisible to this sweep.

## Files

| file | what it is |
|---|---|
| `rocm10-fix1-fix2b.patch` | both fixes ported to the 10.0 source (`therock-10.0` = `6b0e43f341`), 4 files / 43 insertions. Most of it re-derives #10022's guards for a tree their patch does not apply to. |
| `pr10714-rebased-develop.patch` | **the guard hunk extracted from PR #10714**, rebased onto `develop` (1 file / 10 insertions), with a `base-commit:` trailer for `git am -3`. Not the whole PR: #10714 also carries the regression test. Provided for applying the fix to a local tree. |
| `port-fixes-to-10.py` | anchored applier; aborts unless each anchor matches exactly once |
| `LIB-MANIFEST.md` | one row per arm: library path, soname, sha256, source tree, patches, rc, plus the run ledger |
| `VALIDATION.md` | native-build evidence for the port |
| `FAULT-CHAINS.md` | the two fault-evidence chains kept separate (symbol-proven vs instruction-level), and the null result in full |
| `PRIOR-ART-SWEEP.md` | upstream currency gate: both defects KNOWN-OPEN at `develop` tip |

The reproducer itself is unchanged and lives in the repo root as `residual_repro.hip`.
