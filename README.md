# ROCm HIP-graph fixes: NULL-write crash + silent stale-packet execution

Two patches for a defect family in ROCm's HIP-graph exec-update path that bites
long-context llama.cpp serving on RDNA3 (and reproduces on RDNA4): under
device-memory exhaustion, `hipGraphExecUpdate` first crashed the process
(NULL-destination `nontemporalMemcpy`), and with the crash fixed, silently
executed stale kernel arguments while reporting success.

Upstream: crash reported as ROCm/rocm-systems#10021 with fix PR #10022 (not ours;
backported here). The silent-execution defect and its fix are ours (PR pending).

## What these patches are, honestly

They fix the runtime's two defective RESPONSES to kernarg-pool exhaustion. They do
NOT fix the exhaustion itself: the graph kernarg allocator only ever advances
(`GraphKernelArgManager` bump allocation; slots are never reclaimed within an
exec's lifetime), so a long-lived exec updated per token at the VRAM floor WILL
exhaust its pool, on schedule. With these patches the failure surfaces as
`hipErrorGraphExecUpdateFailure`; llama.cpp's existing fallback then destroys and
re-instantiates the graph, which is currently the only way the pool is reclaimed.
Measured on gfx1100 at 0 MiB free: one failure per ~4.1k updates, 25 consecutive
recovery cycles, 102,600 verified-bit-exact launches, no resource creep. The
allocator-side fix (slot reuse on update) belongs upstream.

## Results (gfx1100, llama.cpp master b3c3b96, Qwen 27B Q4_K_XL, c=217088)

| runtime | outcome at the VRAM floor |
|---|---|
| stock 7.14 (also 6.4.4/7.2.2/7.2.4) | SIGSEGV; 5 of 8 deep runs that entered the trigger region crashed |
| + PR #10022 only | silent wrong output (stale kernel args), later malformed AQL packet -> queue abort; on our host one such abort leaked 25.7 GB in KFD and needed a host reboot |
| + both patches | zero crashes/corruption in 32 deep runs; 7 runs crossed the previously always-fatal depth band; deepest 209,439 tokens |

## Files

- `01-pr10022-nullcheck-backport-714.diff` — upstream PR #10022 (author: nycdubliner),
  backported to the `therock-7.14` tag. Not our work; included for one-step patching.
- `02-updateaql-propagate-guef.diff` — our fix: propagate `UpdateAQLPacket()` failure
  out of `hipGraphExecUpdate` (`hip_graph.cpp:2829`) instead of returning success.
- `apply-and-build.sh` — clone the tag, apply both, build `libamdhip64`; use via `LD_PRELOAD`.
- `residual_repro.hip` — standalone reproducer (derived from PR #10022's regression
  test, MIT): shows crash on stock, silent corruption with #10022 alone, clean error
  with both patches.
- `recover_verify.hip` — the recovery-correctness probe: ggml-style
  destroy/re-instantiate loop at 0 MiB free with per-launch output verification.

Workaround with no patches: `GGML_CUDA_DISABLE_GRAPHS=1` (slower, crash-free), or
the Vulkan backend (never affected).

## Kernel-side status (bug 3: KFD VRAM leak after CP fault) — updated 2026-08-25

The third member of this defect family — KFD leaking the dead process's VRAM (persistent
`/sys/class/kfd/kfd/proc/<pid>`, device unusable until reboot) after the CP fault — is a
kernel driver bug, **fixed upstream in Linux 6.15**. Per Felix Kuehling on amd-gfx: a missing
`kfd_unref_process` in `kfd_dqm_suspend_bad_queue_mes` (kfd_device_queue_manager.c) on the
`SOC15_INTSRC_CP_BAD_OPCODE` event path, fixed incidentally by commit
`8544374c0f82edb285779f21b149826fe2c2977c` ("drm/amdkfd: Have kfd driver use same PASID
values from graphic driver"). The ROCm DKMS driver package also carried the fix; we hit it
because we ran the in-tree driver of an EOL 6.14 kernel.

If you see wedged cards from this workload shape: a kernel >= 6.15 (or the ROCm DKMS driver)
removes the leak. The userspace patches here are still required on every kernel — they stop
the crash and the silent corruption that trigger the fault in the first place. We are
re-validating the teardown on 7.0.14 now and will note the result here.
