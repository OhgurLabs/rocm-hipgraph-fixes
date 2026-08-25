#!/bin/bash
# Apply both HIP-graph fixes to the rocm-systems therock-7.14 tag and build libamdhip64.
# Usage: ./apply-and-build.sh /path/to/rocm-7.14-sdk   (the extracted Core SDK tree)
set -euo pipefail
R=${1:?usage: apply-and-build.sh /path/to/rocm-7.14-sdk}
W=$(pwd)/build-work
mkdir -p "$W" && cd "$W"
[ -d src ] || git clone --depth 1 --filter=blob:none --sparse -b therock-7.14 \
    https://github.com/ROCm/rocm-systems.git src
git -C src sparse-checkout set projects/clr projects/hip
git -C src checkout -- projects/clr
git -C src apply "$W/../01-pr10022-nullcheck-backport-714.diff"
git -C src apply "$W/../02-updateaql-propagate-guef.diff"
cmake -S src/projects/clr -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCLR_BUILD_HIP=ON -DCLR_BUILD_OCL=OFF -DHIP_PLATFORM=amd \
  -DHIP_COMMON_DIR="$W/src/projects/hip" -DROCM_PATH="$R" -DHIP_PATH="$R" \
  -DCMAKE_PREFIX_PATH="$R" -D__HIP_ENABLE_PCH=OFF -DUSE_PROF_API=OFF
cmake --build build --target amdhip64 -j"$(nproc)"
LIB=$(find build -name 'libamdhip64.so.7*' -type f | head -1)
echo "Patched lib: $LIB"
echo "Use via: LD_PRELOAD=$LIB your-app   (keep your normal LD_LIBRARY_PATH)"
