// Pass-1 probe: does the ggml-style recovery (910 -> destroy -> re-instantiate -> launch)
// produce CORRECT results, repeatedly, without resource creep?
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <vector>
#define CHECK(what, call) do{ hipError_t e_=(call); if(e_!=hipSuccess){ \
  printf("FATAL %s -> %s\n", what, hipGetErrorString(e_)); exit(2);} }while(0)
namespace { __global__ void WriteValue(int* out, int v){ *out = v; } }
int main(int argc, char** argv){
  long cycles = argc>1 ? atol(argv[1]) : 20;
  int* d_out=nullptr; CHECK("malloc", hipMalloc(&d_out, sizeof(int)));
  hipGraph_t g{}; CHECK("create", hipGraphCreate(&g,0));
  int value=0; void* ka[]={&d_out,&value};
  hipKernelNodeParams np{}; np.func=(void*)WriteValue; np.gridDim=dim3(1);
  np.blockDim=dim3(1); np.kernelParams=ka;
  hipGraphNode_t kn{}; CHECK("addnode", hipGraphAddKernelNode(&kn,g,nullptr,0,&np));
  hipGraphExec_t ge{}; CHECK("inst", hipGraphInstantiate(&ge,g,nullptr,nullptr,0));
  value=1; CHECK("prime", hipGraphLaunch(ge,nullptr)); CHECK("sync0", hipStreamSynchronize(nullptr));
  std::vector<void*> hogs; size_t chunk=size_t{1}<<30;
  while(chunk >= (size_t{4}<<10)){ void* p=nullptr;
    if(hipMalloc(&p,chunk)==hipSuccess) hogs.push_back(p); else chunk>>=1; }
  (void)hipGetLastError();
  size_t f0=0,t0=0; hipMemGetInfo(&f0,&t0);
  printf("exhausted: %.1f MiB free; recover-verify cycles=%ld\n", f0/1048576.0, cycles);
  long i=1, recoveries=0, verified=0;
  while(recoveries < cycles){
    ++i; value=(int)i;
    CHECK("setparams", hipGraphKernelNodeSetParams(kn,&np));
    hipGraphNode_t en{}; hipGraphExecUpdateResult ur{};
    hipError_t st = hipGraphExecUpdate(ge,g,&en,&ur);
    if(st!=hipSuccess){
      if(st!=hipErrorGraphExecUpdateFailure){ printf("UNEXPECTED code %d at i=%ld\n",(int)st,i); return 3; }
      (void)hipGetLastError();
      CHECK("destroy", hipGraphExecDestroy(ge));           // ggml fallback, exactly
      hipError_t ri = hipGraphInstantiate(&ge,g,nullptr,nullptr,0);
      if(ri!=hipSuccess){ printf("REINSTANTIATE FAILED at i=%ld -> %s\n", i, hipGetErrorString(ri)); return 4; }
      ++recoveries;
    }
    CHECK("launch", hipGraphLaunch(ge,nullptr));
    CHECK("sync", hipStreamSynchronize(nullptr));
    int seen=-1; CHECK("readback", hipMemcpy(&seen,d_out,sizeof(int),hipMemcpyDeviceToHost));
    if(seen!=(int)i){ printf("WRONG VALUE after %ld recoveries: got %d want %ld  HIDING=TRUE\n",recoveries,seen,i); return 5; }
    ++verified;
    if(recoveries && (recoveries%5==0) && st!=hipSuccess){
      size_t fr=0,tt=0; hipMemGetInfo(&fr,&tt);
      printf("  recovery %ld at i=%ld: verified=%ld free=%.1f MiB\n",recoveries,i,verified,fr/1048576.0); fflush(stdout);
    }
  }
  size_t f1=0,t1=0; hipMemGetInfo(&f1,&t1);
  printf("DONE: %ld recoveries, %ld verified-correct launches, free before %.1f MiB after %.1f MiB\n",
         recoveries, verified, f0/1048576.0, f1/1048576.0);
  for(void* p:hogs) (void)hipFree(p);
  (void)hipGraphExecDestroy(ge); (void)hipGraphDestroy(g); (void)hipFree(d_out);
  return 0;
}
