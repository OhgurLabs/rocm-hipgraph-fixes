# VALIDATION — `rocm10-fix1-fix2b.patch` on ROCm 10.0.0 / gfx1100
> **Status: partially superseded (2026-08-28).** Written before the AMD 10.1-nightly arms (F/F2)
> and the fix2b-only arm (E2). Its content remains accurate; it is not the full arm set. See
> `README.md` for the reading order and `LIB-MANIFEST.md` for every arm.


Scope of this document: evidence for **this patch, built natively from the ROCm 10.0.0 source**.
Nothing here relies on the earlier cross-version preload experiment; that is recorded separately in
§4 and is explicitly **not** offered as proof of this patch.

## 1. What was built

| item | value |
|---|---|
| patch | `rocm10-fix1-fix2b.patch` — 110 lines, sha256 `423aa161c8003bfb`, 4 files, **43 insertions, 0 deletions** |
| applied by | `port-fixes-to-10.py` (exact-string anchors, aborts unless each matches exactly once) |
| source | `github.com/ROCm/rocm-systems` tag `therock-10.0` = `6b0e43f341195e203754e08f850e437ff2fc09f9` |
| source identity cross-check | the installed ROCm 10.0.0 reports `AMDSMI Tool: 27.0.0+6b0e43f3`, i.e. the same commit |
| build recipe | `cmake -S projects/clr -DCLR_BUILD_HIP=ON -DCLR_BUILD_OCL=OFF -DHIP_PLATFORM=amd -DHIP_COMMON_DIR=<src>/projects/hip -DROCM_PATH=<rocm-10.0 prefix> -DCMAKE_BUILD_TYPE=RelWithDebInfo`, target `amdhip64` |
| produced | `libamdhip64.so.7.15.26333-6b0e43f341`, sha256 `7a42ee09f9084eaf`, 94,746,096 B |
| hardware | AMD Radeon RX 7900 XTX (gfx1100), 294 W cap read back from `power1_cap` |
| kernel / driver | Linux `7.0.14-14-pve`, in-tree amdgpu; `rocminfo` from the 10.0 prefix reports `ROCk module is loaded`, HSA runtime 1.21 |

## 2. Reproducer result — NATIVE 10.0 build

Instrument: `residual_repro` (the same reproducer used to validate the fix on the 7.14 line).
It exhausts device memory, then repeatedly updates and relaunches a captured single-node graph,
checking the value the kernel actually wrote each round.

| runtime under test | rc | observed |
|---|---|---|
| **ROCm 10.0.0 as shipped** (its own `libamdhip64.so.7.15.26333`) | **139** | `Segmentation fault`; kernel log: `segfault at 0 ip … error 6 in libamdhip64.so.7.15.26333-0000000[611c24,…]` |
| **ROCm 10.0.0 + this patch, built natively** | **1** | `STOP round 83107: hipGraphExecUpdate -> the graph update was not performed because it included changes which violated constraints`; `SUMMARY: last_ok_round=83106` |

Both arms ran on the same card in the same window, back to back, with the only difference being
which `libamdhip64` was loaded. Artifacts:
the stock-arm reproducer output (artifact retained locally) and
`.../repro-ported-fix1-fix2b.out`.

**Bug separation, also on a 10.0 base:** with only the bug-1 guards present the crash disappears
but the silent fault remains and the reproducer catches it —
`STALE-PACKET round 83107: kernel wrote 83106, expected 83107 (silent corruption)`, exit 3
(`residual_repro.hip:112-113`). Artifact:
the fix1-only arm's reproducer output (artifact retained locally). This is why both hunks
are needed: bug 1 is the crash, bug 2 is the wrong answer left behind once the crash is gone.

## 3. Application-level result — NATIVE 10.0 build

A 217k-context agentic workload under llama.cpp (HIP backend, gfx1100), run on the ROCm 10.0.0
prefix with this patch's library:

- first attempt **valid**, no segfault, zero invalidity findings
- 35 requests, depth 153,472 tokens, 1029 s wall
- the harness's own gate recorded the loaded runtime from the live process:
  `rocm=[<our built libamdhip64>, <rocm-10.0 prefix>]`

For contrast, on the same harness and card, **stock** ROCm 10.0.0 segfaulted its first attempt at
depth 215,482. Run dir: internal serving-harness cert run; artifact retained locally.

## 4. Separate experiment — NOT evidence for this patch

Before porting, we preloaded a **7.14-built** patched `libamdhip64` onto the ROCm 10.0.0 stack. It
also produced the graceful `rc=1` outcome. That experiment tells us the defect lives in `clr` and
that our guard addresses it irrespective of base version, but it mixes a 7.14 HIP runtime with
10.0's rocBLAS and HSA, which is an unsupported combination. **It is recorded only for provenance
and is deliberately excluded from the claims in §2 and §3**, all of which come from the natively
built library.

## 5. Upstream currency

See `PRIOR-ART-SWEEP.md` (same directory). Both defects verified present at `develop` tip
`e92445f708bfd09d679363144948fa60af6bebdc` on 2026-08-27. Bug 1 is tracked by issue #10021 with
PR #10022 open (author `nycdubliner`, not us). Bug 2 is our PR #10714, open. The bug-2 call site has
drifted 2829 → 2828 (`therock-10.0`) → 2831 (`develop` today), so line numbers must be re-verified
on the day of any submission.

## 6. Note on hunk placement, for reviewers

The bug-1 guard in `hip_graph_internal.hpp` does **not** return from inside the capture loop; it
records the failure, lets the loop finish so every `command->release()` still runs, and only then
clears both packet vectors and `commands_` before returning. That addresses the concern raised
against an in-loop early return in review on PR #10022.
