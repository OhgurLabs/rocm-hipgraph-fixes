#!/usr/bin/env python3
"""Port our two HIP fixes onto ROCm therock-10.0 (rocm-systems 6b0e43f3).

This is a REBASE, not a transplant. The 7.14 patches do not apply: the graph-update path lost its
IsSegmentSchedulingEnabled() condition, the packet-capture loop gained gpuMetadataPackets_, and the
blit const buffer was renamed constBuf -> kernArgBase in one of its three sites. Two deliberate
improvements over the 7.14 patch:
  * rocblit batchMemOps (a THIRD unguarded graph-kernarg site) is covered too.
  * rocvirtual's guard is placed after the if/else so the non-graph allocKernArg branch is
    covered as well, not only the graph-capture branch.

Every anchor must match EXACTLY once or the script aborts without writing anything.

Bug 1 (upstream PR #10022, not ours): a kernarg / const-buffer allocation failure is never checked,
        so a NULL pointer reaches memcpy / the packet build.
Bug 2 (ours, PR #10714):  hipGraphExecUpdate assigns UpdateAQLPacket()'s status and drops it, so a
        re-capture failure returns hipSuccess and the next launch replays a STALE packet.
"""
import subprocess, sys
from pathlib import Path

SRC = Path("/data18t/clr-fix10/src/projects/clr")

EDITS = []

# ---------------------------------------------------------------- bug 1, site 1: capture loop
gi = SRC / "hipamd/src/hip_graph_internal.hpp"
EDITS.append((gi,
"""    gpuPackets_.clear();
    gpuMetadataPackets_.clear();

    for (auto& command : commands_) {""",
"""    gpuPackets_.clear();
    gpuMetadataPackets_.clear();

    // A kernarg allocation failure inside submit() marks the command with a negative status
    // (see VirtualGPU::submitKernelInternal) instead of forming a packet.  Track it so the
    // capture does not report success while gpuPackets_ holds nothing for that node.
    hipError_t submit_status = hipSuccess;
    for (auto& command : commands_) {"""))

EDITS.append((gi,
"""      command->submit(*(command->queue())->vdev());
      command->release();""",
"""      command->submit(*(command->queue())->vdev());
      if (submit_status == hipSuccess && command->status() < 0) {
        submit_status = hipErrorOutOfMemory;
      }
      command->release();"""))

EDITS.append((gi,
"""    // The metadata capture path appends one metadata packet per AQL packet, but""",
"""    if (submit_status != hipSuccess) {
      // Drop the partial capture: leaving half-populated, index-desynchronised packet vectors
      // behind is what turns an allocation failure into a stale-packet launch later on.
      std::for_each(gpuPackets_.begin(), gpuPackets_.end(), [](auto p) { delete[] p; });
      std::for_each(gpuMetadataPackets_.begin(), gpuMetadataPackets_.end(),
                    [](auto p) { delete[] p; });
      gpuPackets_.clear();
      gpuMetadataPackets_.clear();
      commands_.clear();
      return submit_status;
    }
    // The metadata capture path appends one metadata packet per AQL packet, but"""))

# ---------------------------------------------------------------- bug 1, sites 2-4: rocblit
rb = SRC / "rocclr/device/rocm/rocblit.cpp"
EDITS.append((rb,
"""          : (unsigned char*)gpu().allocKernArg(kCBSize, kCBAlignment);""",
"""          : (unsigned char*)gpu().allocKernArg(kCBSize, kCBAlignment);
  if (kernArgBase == nullptr) {
    LogError("fillBuffer1D: failed to allocate the fill constant buffer (out of memory)");
    return false;
  }"""))

EDITS.append((rb,
"""                        : gpu().allocKernArg(kCBSize, kCBAlignment);""",
"""                        : gpu().allocKernArg(kCBSize, kCBAlignment);
    if (constBuf == nullptr) {
      LogError("fillBuffer2D: failed to allocate the fill constant buffer (out of memory)");
      return false;
    }"""))

EDITS.append((rb,
"""      : gpu().allocKernArg(count * paramSize, kCBAlignment);""",
"""      : gpu().allocKernArg(count * paramSize, kCBAlignment);
  if (constBuf == nullptr) {
    LogError("batchMemOps: failed to allocate the parameter buffer (out of memory)");
    return false;
  }"""))

# ---------------------------------------------------------------- bug 1, site 5: rocvirtual
rv = SRC / "rocclr/device/rocm/rocvirtual.cpp"
EDITS.append((rv,
"""    amd::nontemporalMemcpy(argBuffer, parameters, argSize);""",
"""    if (argBuffer == nullptr) {
      LogError("submitKernelInternal: failed to allocate the kernel argument buffer (out of memory)");
      return false;
    }
    amd::nontemporalMemcpy(argBuffer, parameters, argSize);"""))

# ---------------------------------------------------------------- bug 2: hipGraphExecUpdate
gc = SRC / "hipamd/src/hip_graph.cpp"
EDITS.append((gc,
"""          status = graphExec->UpdateAQLPacket(reinterpret_cast<hip::GraphKernelNode*>(oldGraphExecNodes[i]));""",
"""          status = graphExec->UpdateAQLPacket(reinterpret_cast<hip::GraphKernelNode*>(oldGraphExecNodes[i]));
          if (status != hipSuccess) {
            // A packet re-capture failure (e.g. kernarg allocation under device-memory
            // exhaustion) leaves the exec holding the PREVIOUSLY captured packet.  Reporting
            // success here makes the next launch execute that stale packet: silent output
            // corruption, and with kernarg-pool recycling a malformed AQL packet.  Surface it.
            *hErrorNode_out = reinterpret_cast<hipGraphNode_t>(newGraphNodes[i]);
            *updateResult_out = hipGraphExecUpdateError;
            HIP_RETURN(hipErrorGraphExecUpdateFailure);
          }"""))

# ---------------------------------------------------------------- apply
texts = {}
for path, anchor, repl in EDITS:
    texts.setdefault(path, path.read_text())

fail = False
for i, (path, anchor, repl) in enumerate(EDITS, 1):
    n = texts[path].count(anchor)
    if n != 1:
        print(f"ABORT edit {i}: anchor matched {n} times in {path.name} (need exactly 1)")
        print(f"  anchor: {anchor.splitlines()[0][:90]}")
        fail = True
if fail:
    sys.exit(1)

for path, anchor, repl in EDITS:
    texts[path] = texts[path].replace(anchor, repl, 1)
for path, text in texts.items():
    path.write_text(text)
    print(f"patched {path.relative_to(SRC)}")

print("\n=== git diff --stat ===")
print(subprocess.run(["git", "-C", "/data18t/clr-fix10/src", "diff", "--stat"],
                     capture_output=True, text=True).stdout)
