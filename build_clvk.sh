#!/usr/bin/env bash
# clvk-install.sh — download, build and install clvk (OpenCL 3.0 on Vulkan)
# as an ICD next to rusticl, on Ubuntu 26.04 (host or container).
#
# Result:
#   /usr/local/lib/clvk/libclvk.so        clvk (renamed, own SONAME)
#   /usr/local/lib/clvk/clspv             offline compiler (only if built)
#   /etc/OpenCL/vendors/clvk.icd          ICD registration
#   /etc/profile.d/clvk.sh                VK_DRIVER_FILES + CLVK env
#
# Tunables (env):
#   CLVK_REF=main            git branch/tag/commit of clvk
#   SRC_DIR=/opt/src/clvk    source + build location (kept for incremental rebuilds)
#   PREFIX=/usr/local/lib/clvk
#   RADV_JSON=               Vulkan ICD json to pin (auto: prefer /usr/local, i.e. own Mesa build)
#   JOBS=$(nproc)
#   CLEAN=0                  1 = wipe build dir first
set -euo pipefail

CLVK_REF="${CLVK_REF:-main}"
SRC_DIR="${SRC_DIR:-/opt/src/clvk}"
BUILD_DIR="${SRC_DIR}/build"
PREFIX="${PREFIX:-/usr/local/lib/clvk}"
JOBS="${JOBS:-$(nproc)}"
CLEAN="${CLEAN:-0}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------- deps
log "Installing build + runtime dependencies"
$SUDO apt-get update
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends \
  git ca-certificates cmake ninja-build python3 g++ lld ccache patchelf \
  libvulkan-dev vulkan-tools ocl-icd-libopencl1 ocl-icd-opencl-dev clinfo

# ---------------------------------------------------------------- source
if [ ! -d "${SRC_DIR}/.git" ]; then
  log "Cloning clvk (${CLVK_REF})"
  $SUDO mkdir -p "$(dirname "${SRC_DIR}")"
  $SUDO chown "$(id -u):$(id -g)" "$(dirname "${SRC_DIR}")"
  git clone https://github.com/kpet/clvk.git "${SRC_DIR}"
fi
cd "${SRC_DIR}"
log "Checking out ${CLVK_REF} and syncing submodules"
git fetch --tags origin
git checkout "${CLVK_REF}"
git pull --ff-only 2>/dev/null || true          # no-op on tags/commits
git submodule sync --recursive
git submodule update --init --recursive

log "Fetching LLVM for clspv (pinned by clspv itself)"
python3 ./external/clspv/utils/fetch_sources.py --deps llvm

# ---------------------------------------------------------------- build
[ "${CLEAN}" = "1" ] && rm -rf "${BUILD_DIR}"
log "Configuring (Release, Ninja, no LLVM backends, lld, ccache)"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_TARGETS_TO_BUILD="" \
  -DLLVM_USE_LINKER=lld \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DCLVK_CLSPV_ONLINE_COMPILER=ON

log "Building with ${JOBS} jobs (first build compiles LLVM — this is the long part)"
cmake --build "${BUILD_DIR}" -j"${JOBS}"

# ---------------------------------------------------------------- install
LIB="$(find "${BUILD_DIR}" -maxdepth 2 -name 'libOpenCL.so*' -type f | head -n1)"
[ -n "${LIB}" ] || { echo "clvk libOpenCL.so not found in ${BUILD_DIR}" >&2; exit 1; }

log "Installing to ${PREFIX}"
$SUDO install -d "${PREFIX}"
$SUDO install -m755 "${LIB}" "${PREFIX}/libclvk.so"
# Own SONAME so it can never be confused with the ICD loader's libOpenCL.so.1
$SUDO patchelf --set-soname libclvk.so "${PREFIX}/libclvk.so"

CLSPV_BIN="$(find "${BUILD_DIR}" -maxdepth 4 -name clspv -type f -perm -u+x | head -n1 || true)"
if [ -n "${CLSPV_BIN}" ]; then
  $SUDO install -m755 "${CLSPV_BIN}" "${PREFIX}/clspv"
  echo "installed offline clspv: ${PREFIX}/clspv"
fi

log "Registering ICD"
$SUDO install -d /etc/OpenCL/vendors
echo "${PREFIX}/libclvk.so" | $SUDO tee /etc/OpenCL/vendors/clvk.icd >/dev/null

# ---------------------------------------------------------------- vulkan pin
# Two RADV jsons (own Mesa + distro Mesa) make clvk list the same GPU twice.
if [ -z "${RADV_JSON:-}" ]; then
  RADV_JSON="$(ls /usr/local/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -n1 || true)"
  [ -z "${RADV_JSON}" ] && RADV_JSON="$(ls /usr/share/vulkan/icd.d/radeon_icd*.json 2>/dev/null | head -n1 || true)"
fi

log "Writing /etc/profile.d/clvk.sh"
{
  echo "# clvk runtime environment"
  [ -n "${RADV_JSON}" ] && echo "export VK_DRIVER_FILES=${RADV_JSON}"
  [ -n "${CLSPV_BIN}" ] && echo "export CLVK_CLSPV_PATH=${PREFIX}/clspv"
  echo "export CLVK_LOG=\${CLVK_LOG:-1}"
} | $SUDO tee /etc/profile.d/clvk.sh >/dev/null
cat /etc/profile.d/clvk.sh

# ---------------------------------------------------------------- verify
log "Verification"
# shellcheck disable=SC1091
. /etc/profile.d/clvk.sh
ldd "${PREFIX}/libclvk.so" | grep 'not found' && { echo "missing deps above" >&2; exit 1; } || true
nm -D "${PREFIX}/libclvk.so" | grep -q clIcdGetPlatformIDsKHR \
  && echo "ICD entry point: ok" || echo "WARNING: no clIcdGetPlatformIDsKHR export"
vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' || true
clinfo -l

cat <<EOF

Done. Notes:
  - docker exec shells are not login shells: run '. /etc/profile.d/clvk.sh'
    or pass VK_DRIVER_FILES via 'docker run -e'.
  - Both rusticl and clvk should now be listed; pin Qrack with
    QRACK_OCL_DEFAULT_DEVICE=<index from 'clinfo -l' order>.
  - Rebuild later: CLVK_REF=<ref> $0   (ccache + kept build dir make it fast)
EOF
