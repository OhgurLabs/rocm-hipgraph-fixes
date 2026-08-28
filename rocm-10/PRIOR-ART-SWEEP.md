# PRIOR-ART-SWEEP — ROCm HIP graph defects, ROCm 10.0.0 port
Swept 2026-08-27. Gate: `upstream-prior-art` (mandatory before any submission or public
unfixed-claim). This artifact must exist before anything goes out; it does.

## 1. True upstream
- Component: ROCm userspace HIP runtime (`clr`) in the monorepo **github.com/ROCm/rocm-systems**.
- Development branch: **`develop`**. Tags lag it badly.
- Tip checked: **`e92445f708bfd09d679363144948fa60af6bebdc`** (2026-08-27T23:39Z).
- Release tag we installed: `therock-10.0` = **`6b0e43f341195e203754e08f850e437ff2fc09f9`** (2026-08-19).
  `develop` is **1,756 commits ahead** of the common merge base (`920e5a8a`, 2026-07-28).
- The line we run locally (7.14) says nothing about upstream state — that is the whole point of
  this gate, and it is why the 6.15 kernel miss happened.

## 2. Prior-art queries run (all on ROCm/rocm-systems, open AND closed)
`hipGraphExecUpdate` (9 hits) · `UpdateAQLPacket` (7) · `getGraphKernArg` (3) · `allocKernArg` (7) ·
`fillBuffer1D` (3) · `"stale packet"` (15) · `hipErrorGraphExecUpdateFailure` (2) · `kernarg` (135);
plus direct reads of #10021, #10022, #10713, #10714; plus `ROCm/clr` and `ROCm/ROCm`
(#6178 gfx1100 stream-ordered alloc segfaults, #6529 gfx1100 address-zero VM faults) and
downstream `ggml-org/llama.cpp#11949`. Commit history on `develop` since 2026-06-01 for all four
paths was listed; **no commit has added the missing NULL checks or propagated the
`UpdateAQLPacket` status.** AMD community forums: no thread describing either defect.

## 3. Tip verification — both defects PRESENT at `develop` tip e92445f
- **Bug 1** (unchecked kernarg / const-buffer allocation → NULL write), four sites:
  `hip_graph_internal.hpp` capture loop (tip 298–305), `rocblit.cpp` `fillBuffer1D`
  (tip 2467–2470, memcpy at 2554), `rocblit.cpp` `fillBuffer2D` (tip 2645–2649),
  `rocvirtual.cpp` `submitKernelInternal` (tip 4900–4909, `nontemporalMemcpy` unguarded).
- **Bug 2** (`hipGraphExecUpdate` drops `UpdateAQLPacket` status → stale packet replay):
  tip **2831–2834**; `status` assigned, never inspected, function then returns
  `hipGraphExecUpdateSuccess` / `hipSuccess`.
- **Line drift, recorded because the gate demands it:** this call site was 2829 in our original
  RCA, 2828 in `therock-10.0`, and is **2831 on develop today** (upstream `BatchMemOp` capture
  commits moved it). Re-check on the day of submission, not the day of drafting.

## 4. Existing PR status
| PR | subject | author | state | head | notes |
|---|---|---|---|---|---|
| [#10022](https://github.com/ROCm/rocm-systems/pull/10022) | fail cleanly when graph kernarg allocation fails | `nycdubliner` (**not us**) | **OPEN**, mergeable | `e19f1a1e` | Maintainer `chrispaquot` asked on `hip_graph_internal.hpp:306` *"can't you just return here?"*; author replied that an early return inside the loop would leak unreleased `commands_` references |
| [#10714](https://github.com/ROCm/rocm-systems/pull/10714) | propagate UpdateAQLPacket failure out of hipGraphExecUpdate | `Ohgur` (**ours**) | **OPEN**, mergeable, awaiting maintainer | `0189a10b` | root cause in [#10713](https://github.com/ROCm/rocm-systems/issues/10713); validation comment on [#10021](https://github.com/ROCm/rocm-systems/issues/10021) |

Neither is merged to `develop`; neither is contained in `therock-10.0`, i.e. **neither is in the
shipped ROCm 10.0.0.**

## 5. Verdict per defect
- **Bug 1 — `KNOWN-OPEN`** (issue #10021, fix proposed in PR #10022, unmerged at tip).
- **Bug 2 — `KNOWN-OPEN`** (our PR #10714, unmerged at tip; root cause #10713).

## Claim boundary — what we may and may not say publicly
**ALLOWED:** both defects are verified present at `develop` tip `e92445f` on 2026-08-27; they ship
in ROCm 10.0.0 (`therock-10.0`); both are already reported upstream with open PRs (#10022 by
another contributor, #10714 ours) awaiting maintainer merge; we ported both fixes onto the 10.0
source and measured the behaviour change on our own reproducer.

**NOT ALLOWED:** claiming either defect is novel or unreported; claiming "no fix exists"; claiming
either fix is merged into ROCm; implying #10022 is our work.

## Note for our own PR quality
Our ported fix1 site-1 hunk completes the capture loop (so every `command->release()` still runs)
and only *then* returns the error, clearing both packet vectors. That placement sidesteps exactly
the objection `chrispaquot` raised against an in-loop early return on #10022 — worth saying if we
comment there.
