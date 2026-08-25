// Standalone reproducer for ROCm/rocm-systems#10021 + its residual defect.
// Derived from PR #10022's Unit_hipGraphExecUpdate_KernargPoolExhaustion
// (author: nycdubliner, SPDX MIT), de-framework'd and instrumented:
//   --iters N        update budget (default 262144)
//   --update-only    no launches between updates (isolates the update path)
//   --headroom BYTES stop exhausting when this much stays free (default 0)
//   --report N       progress line every N iters (default 10000)
// Fail-fast: every fallible call aborts immediately, naming round and call.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#define CHECK(round, what, call)                                              \
  do {                                                                        \
    hipError_t e_ = (call);                                                   \
    if (e_ != hipSuccess) {                                                   \
      std::printf("FAIL round %d: %s -> %s (%d)\n", (round), (what),          \
                  hipGetErrorString(e_), (int)e_);                            \
      std::fflush(stdout);                                                    \
      std::exit(2);                                                           \
    }                                                                         \
  } while (0)

namespace {
__global__ void WriteValue(int* out, int value) { *out = value; }
}

int main(int argc, char** argv) {
  long iters = 262144, report = 10000; size_t headroom = 0; bool update_only = false;
  for (int a = 1; a < argc; ++a) {
    if (!std::strcmp(argv[a], "--iters") && a + 1 < argc) iters = atol(argv[++a]);
    else if (!std::strcmp(argv[a], "--report") && a + 1 < argc) report = atol(argv[++a]);
    else if (!std::strcmp(argv[a], "--headroom") && a + 1 < argc) headroom = strtoull(argv[++a], nullptr, 10);
    else if (!std::strcmp(argv[a], "--update-only")) update_only = true;
  }

  hipDeviceProp_t prop{};
  CHECK(0, "hipGetDeviceProperties", hipGetDeviceProperties(&prop, 0));
  size_t free0 = 0, total = 0;
  CHECK(0, "hipMemGetInfo", hipMemGetInfo(&free0, &total));
  std::printf("=== %s (%s) ===\nfree %.2f GiB / total %.2f GiB | iters %ld | update_only %d | headroom %zu\n",
              prop.name, prop.gcnArchName, free0 / 1073741824.0, total / 1073741824.0,
              iters, (int)update_only, headroom);
  std::fflush(stdout);

  int* d_out = nullptr;
  CHECK(0, "hipMalloc d_out", hipMalloc(&d_out, sizeof(int)));

  hipGraph_t graph{};
  CHECK(0, "hipGraphCreate", hipGraphCreate(&graph, 0));
  int value = 0;
  void* kernelArgs[] = {&d_out, &value};
  hipKernelNodeParams nodeParams{};
  nodeParams.func = reinterpret_cast<void*>(WriteValue);
  nodeParams.gridDim = dim3(1);
  nodeParams.blockDim = dim3(1);
  nodeParams.sharedMemBytes = 0;
  nodeParams.kernelParams = kernelArgs;
  nodeParams.extra = nullptr;
  hipGraphNode_t kNode{};
  CHECK(0, "hipGraphAddKernelNode", hipGraphAddKernelNode(&kNode, graph, nullptr, 0, &nodeParams));

  hipGraphExec_t graphExec{};
  CHECK(0, "hipGraphInstantiate", hipGraphInstantiate(&graphExec, graph, nullptr, nullptr, 0));

  value = 1;
  CHECK(1, "prime hipGraphLaunch", hipGraphLaunch(graphExec, nullptr));
  CHECK(1, "prime hipStreamSynchronize", hipStreamSynchronize(nullptr));
  std::printf("baseline: 1-node graph captured, instantiated, launched OK\n");

  // Exhaust device memory: greedy halving-probe allocation, keeping every block.
  std::vector<void*> hogs;
  size_t chunk = size_t{1} << 30, held = 0;
  while (chunk >= (size_t{4} << 10)) {
    size_t fr = 0, to = 0;
    if (hipMemGetInfo(&fr, &to) == hipSuccess && fr <= headroom + chunk) { chunk >>= 1; continue; }
    void* p = nullptr;
    if (hipMalloc(&p, chunk) == hipSuccess) { hogs.push_back(p); held += chunk; }
    else chunk >>= 1;
  }
  static_cast<void>(hipGetLastError());
  size_t free1 = 0;
  CHECK(1, "hipMemGetInfo post-exhaust", hipMemGetInfo(&free1, &total));
  std::printf("exhausted: held %.2f GiB in %zu blocks, %.1f MiB reported free\n",
              held / 1073741824.0, hogs.size(), free1 / 1048576.0);
  std::fflush(stdout);

  hipError_t status = hipSuccess;
  long last_ok = 1;
  for (long i = 2; i <= iters; ++i) {
    value = (int)i;
    CHECK((int)i, "hipGraphKernelNodeSetParams", hipGraphKernelNodeSetParams(kNode, &nodeParams));
    hipGraphNode_t errorNode{};
    hipGraphExecUpdateResult updateResult{};
    status = hipGraphExecUpdate(graphExec, graph, &errorNode, &updateResult);
    if (status != hipSuccess) {
      std::printf("STOP round %ld: hipGraphExecUpdate -> %s (%d), updateResult=%d errorNode=%p\n",
                  i, hipGetErrorString(status), (int)status, (int)updateResult, (void*)errorNode);
      break;
    }
    if (!update_only) {
      status = hipGraphLaunch(graphExec, nullptr);
      if (status != hipSuccess) { std::printf("STOP round %ld: hipGraphLaunch -> %s (%d)\n", i, hipGetErrorString(status), (int)status); break; }
      status = hipStreamSynchronize(nullptr);
      if (status != hipSuccess) { std::printf("STOP round %ld: hipStreamSynchronize -> %s (%d)\n", i, hipGetErrorString(status), (int)status); break; }
      int seen = -1;
      status = hipMemcpy(&seen, d_out, sizeof(int), hipMemcpyDeviceToHost);
      if (status != hipSuccess) { std::printf("STOP round %ld: hipMemcpy readback -> %s (%d)\n", i, hipGetErrorString(status), (int)status); break; }
      if (seen != (int)i) {
        std::printf("STALE-PACKET round %ld: kernel wrote %d, expected %ld (silent corruption)\n", i, seen, i);
        std::exit(3);
      }
    }
    last_ok = i;
    if (report > 0 && (i % report) == 0) {
      std::printf("  ... round %ld ok\n", i); std::fflush(stdout);
    }
  }

  std::printf("SUMMARY: last_ok_round=%ld status=%s (%d)\n",
              last_ok, hipGetErrorString(status), (int)status);
  std::fflush(stdout);
  for (void* p : hogs) static_cast<void>(hipFree(p));
  static_cast<void>(hipGraphExecDestroy(graphExec));
  static_cast<void>(hipGraphDestroy(graph));
  static_cast<void>(hipFree(d_out));
  return status == hipSuccess ? 0 : 1;
}
