# Round-three challenge passes (2026-08-28)

Three new attacks, chosen as the remaining soft spots rather than repeats of earlier rounds.

## ATTACK 1 (METHOD) — "you deliberately exhausted device memory; failing under exhaustion is allowed"
**Answered from AMD's own shipped header**, `10.1-nightly/include/hip/hip_runtime_api.h`:

```
 * @param [in] hErrorNode_out -  node which caused the permissibility check to forbid the update.
 * @param [in] updateResult_out - Return code whether the graph update was performed.
 * @returns #hipSuccess, #hipErrorGraphExecUpdateFailure
```

The API documents a dedicated failure return **for exactly this situation**, plus two out-params for
reporting which node forbade the update. When `UpdateAQLPacket` fails the update was not performed,
yet the function returns `hipSuccess` with `updateResult_out = hipGraphExecUpdateSuccess`. That is a
**violation of the documented contract in AMD's own header**, independent of memory pressure. Our
patch returns `hipErrorGraphExecUpdateFailure` — one of the two documented values — so it makes the
function conform to its own documentation rather than adding new behaviour.
**Verdict: the exhaustion objection does not survive. Contract defect, not stress artifact.**

## ATTACK 2 (DATA) — "the reproducer is your own code; maybe its check is wrong"
Audited at source (`/data18t/clr-fix714/residual_repro.hip`):
- **Lineage:** line 2 records it as *derived from PR #10022's own unit test*,
  `Unit_hipGraphExecUpdate_KernargPoolExhaustion`. The instrument descends from the upstream PR.
- **Kernel:** `__global__ void WriteValue(int* out, int value) { *out = value; }`.
- **Logic:** per round `value = i`; call `hipGraphExecUpdate`; **only if it returns success** do
  `hipGraphLaunch`, then a blocking `hipMemcpy` D2H and compare `seen != i`.
- **Signature:** the failure prints `seen == i-1` exactly — the *previous* round's value, not
  garbage — which is diagnostic of a replayed stale kernarg; a blocking D2H copy on the null stream
  rules out a read-ordering artifact.
**Verdict: check is sound; the observed value is specific to staleness.**

## ATTACK 3 (SCOPE) — "you have never seen silent corruption in a real workload"
**Tested 2026-08-28. NULL RESULT: the triggering condition never occurred, so nothing could be
observed either way.** Recorded in full because "we looked and saw nothing" and "we looked and the
trigger never fired" are different statements, and only the second is true.

Design (`/root/endgap-silent-corruption.sh`, run dir `rocm10-endgap-20260828/`): identical
deterministic greedy decode (`temperature 0`, `top_k 1`, `seed 1234`, `cache_prompt false`,
`ignore_eos true`) on `llama-server`, `-c 217088`, twice per library — `#10022`-only (B) versus
`#10022`+fix2b (D). Two runs per library establish self-consistency first, without which a
cross-library diff would be meaningless. **Detector:** with fix2b present a surfaced
`hipErrorGraphExecUpdateFailure` makes ggml log `CUDA graph update failed`
(`ggml-cuda.cu:2643`) and re-instantiate, so the D arms reveal whether the path is reached at all.

| arm | library | prompt tok | forced decode | output sha256 | `graph update failed` |
|---|---|---|---|---|---|
| D1 | #10022+fix2b | 16,460 | 20,000 | `fa52465db5aecc1d` | **0** |
| D2 | #10022+fix2b | 16,460 | 20,000 | `fa52465db5aecc1d` | **0** |
| B1 | #10022 only | 16,460 | 20,000 | `fa52465db5aecc1d` | **0** |
| B2 | #10022 only | 16,460 | 20,000 | `fa52465db5aecc1d` | **0** |

- **Determinism control PASSED:** D1≡D2 and B1≡B2 byte-identical, so the method would have detected
  a divergence had one occurred.
- **Cross-library:** D1≡B1 byte-identical. No corruption.
- **Why:** zero detector hits in the D arms. The kernarg pool never exhausted. 20,000 graph updates
  in a single long decode is far short of the ~83,000 the reproducer needs; the cert cell that did
  crash reached exhaustion by a different route (43 separate requests at depth 215k, larger
  kernargs, less headroom).

**Sizing note:** the first two attempts returned HTTP 400. The server's own error was captured
rather than guessed — `send_error: request (309527 …` against `n_ctx` 217,088 — and the prompt was
resized from that number, confirmed by `tokens_eval=16460` on the successful run.

**Therefore, precisely:**
- Sayable: silent wrong results are observed **in the reproducer** (4/4); a real server reaches the
  same code region (its crash sits 0x1e from the reproducer's fault inside one loop-plus-tail
  block); and in a 20,000-update real serving run the stale-packet path **was not reached**.
- NOT sayable: that a real server silently emits wrong tokens. Closing that would need ~80k+ forced
  tokens per arm (~50 min each) or a replication of the deep multi-request cert-cell pattern.
- The necessity argument for #10714 does not rest on this: arm B isolates the behaviour, and AMD's
  own header documents the contract being violated.

---

# FAULT EVIDENCE — two chains, kept separate
Written 2026-08-28. The production crash and the reproducer crash are **separate evidence chains**.
They are presented apart, and the linkage between them is stated as exactly what it is: partly
symbol-proven, partly inferred. Nothing here asserts "same bug" beyond what the evidence carries.

## Per-library address bias — compute it, never assume it
The kernel's `segfault … in <lib>[<offset>,…]` value is a **file offset**. Converting to a virtual
address needs that library's own `.text` bias:

| library | `.text` vaddr | `.text` file off | bias |
|---|---|---|---|
| AMD 10.0.0 shipped | `0x123a10` | `0x122a10` | **+0x1000** |
| AMD 10.1 nightly shipped | `0x123ed0` | `0x122ed0` | **+0x1000** |
| our RelWithDebInfo build | `0x2c3a0` | `0x2c3a0` | **0** |

An earlier analysis of mine disassembled AMD's offsets without the bias and read unrelated
instructions; a later one generalised +0x1000 to our build, which would also have been wrong.
Both corrected here.

---

## CHAIN 1 — our build, symbolised (function named, not inferred)

Library: `lib-fix2b-only/libamdhip64.so.7.15.26333-6b0e43f341`, `RelWithDebInfo`, **not stripped**,
3 debug sections. Arm E2 fault at file offset `661e5b`; bias 0, so vaddr `0x661e5b`.

```
addr2line -f -C -e <our lib> 0x661e5b
  amd::roc::VirtualGPU::submitKernelInternal(amd::NDRangeContainer const&, amd::Kernel const&,
    unsigned char const*, void*, unsigned int, amd::NDRangeKernelCommand*,
    hsa_kernel_dispatch_packet_s*, bool)
  /usr/lib/gcc/x86_64-linux-gnu/13/include/emmintrin.h:1509
```

**What this proves:** the fault is inside `VirtualGPU::submitKernelInternal`, at an **inlined SSE
non-temporal store** (`emmintrin.h` is the SSE2 intrinsic header). That is the
`amd::nontemporalMemcpy(argBuffer, parameters, argSize)` call in
`projects/clr/rocclr/device/rocm/rocvirtual.cpp`, reached with `argBuffer == nullptr` because
`getGraphKernArg` → `AllocKernArg` returned `nullptr` under pool exhaustion and nothing checked it.
This is the same function and the same statement that issue #10021 describes and that PR #10022
guards — established by symbols, in a build compiled from AMD's own `therock-10.0` source.

---

## CHAIN 2 — AMD's shipped builds, instruction-level only (stripped; functions NOT nameable)

AMD's released libraries carry no local symbols, so no function can be named from them. What is
observable is the faulting instruction and its surrounding structure.

| fault | library | file off | vaddr | instruction |
|---|---|---|---|---|
| production `llama-server` | 10.0.0 shipped | `611c24` | `612c24` | `movntdq %xmm0,(%rdi)` |
| reproducer | 10.0.0 shipped | `611c42` | `612c42` | `movnti %rax,(%rdi)` |
| reproducer | **10.1 nightly shipped** | `61a6f2` | `61b6f2` | `movnti %rax,(%rdi)` — bytes `48 0f c3 07` |

Surrounding structure at 10.0.0 (identical shape in 10.1):

```
612c20: <loop body containing 612c24 movntdq %xmm0,(%rdi)>
612c38: jne  612c20          <- backward branch: 16-byte non-temporal copy loop
612c3a: test $0x8,%dl        <- size-bit test: tail handling
612c3d: je   612c4e
612c3f: mov  (%rsi),%rax
612c42: movnti %rax,(%rdi)   <- 8-byte non-temporal tail
```

**What this proves:** all three faults are non-temporal stores through `%rdi`, and every one is
reported as `segfault at 0` with `error 6` (user-mode write to a non-present page), i.e. `%rdi` is
NULL. The two 10.0.0 faults sit 0x1e apart inside a single copy-loop-plus-tail block, so they are
the 16-byte and 8-byte paths of one routine. The 10.1 fault is the byte-identical instruction in
the byte-identical block.

**What this does NOT prove:** the name of that routine in AMD's builds. It is not symbolised.

---

## LINKAGE — what may be claimed, and what may not

**Claimable:**
- Chain 1 names `submitKernelInternal` + an inlined non-temporal store, by symbols, in a build from
  AMD's own source.
- Chain 2 shows AMD's shipped 10.0.0 and 10.1 fault on the same instruction class, through the same
  register, at `segfault at 0`, inside the same loop-plus-tail structure.
- The production crash and the reproducer crash on 10.0.0 are **0x1e apart in one code block**, so
  they are the same code region — this satisfies "adjacent instructions in the same source region"
  without needing symbols.
- Therefore: the reproducer exercises the same code region as the real inference server, and AMD's
  newest build still contains it.

**NOT claimable:**
- That AMD's stripped offsets *are* `submitKernelInternal` — that is an inference from source
  identity plus instruction class, not a symbol match. Say "consistent with", not "is".
- That the production crash and the reproducer crash are literally the same instruction — they are
  not; one is the SIMD path, the other the scalar tail of the same block.
- Anything about `batchMemOps`: no fault has ever been observed through that site.

## Independent corroboration that does not use the reproducer at all
Stock ROCm 10.0.0, real workload: `llama-server`, Qwen3.8-27B-UD-Q4_K_XL, 217k context —
`segfault=True`, depth 215,482, 43 requests
(internal serving-harness run; artifact retained locally). This answers the
"your reproducer is synthetic" objection without relying on the chains above.

## Determinism — every run observed per arm, not a sampled subset
Counts below are **all runs of that arm across every run dir**, so they are on one scale. The
per-directory breakdown, and the file list behind each count, is the run ledger in
`LIB-MANIFEST.md`. (Earlier drafts quoted B as 3/3, counting only the determinism-repeat dir; its
fourth run lives in the sufficiency dir and is identical.)

| arm | runs | outcome |
|---|---|---|
| A stock 10.0.0 | 4/4 | `rc=139` |
| F / F2 AMD 10.1 nightly | 2/2 | `rc=139`, same fault address |
| E2 fix2b alone | 3/3 | `rc=139` |
| B #10022 only | 4/4 | `rc=3`, `STALE-PACKET round 83107: kernel wrote 83106, expected 83107` |
| D #10022 + fix2b | 3/3 | `rc=1`, `STOP round 83107` |

Every arm reproduces at the identical trigger round, consistent with a deterministic
bump-allocator exhaustion boundary rather than a race.
