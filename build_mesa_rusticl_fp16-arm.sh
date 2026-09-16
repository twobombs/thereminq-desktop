#!/usr/bin/env bash
# =============================================================================
# build_mesa_adreno_rusticl_fp16.sh
#
# Android/Termux port of build_mesa_rusticl_fp16.sh.
#
# Builds Mesa (Freedreno KGSL fork) for Qualcomm Adreno GPUs inside a
# proot-distro / chroot Ubuntu 24.04 / 25.x / 26.04 arm64 container:
#   - Turnip  Vulkan  (freedreno, KGSL kernel backend -> /dev/kgsl-3d0)
#   - rusticl OpenCL  on freedreno-kgsl, zink-over-turnip and llvmpipe
#   - custom libclc with the FP16 builtins Ubuntu's package lacks
# Installs to /usr/local/mesa so the distro Mesa stays untouched.
#
# Source: lfdevs/mesa-for-android-container (upstream Mesa + KGSL loader
# patches for containers). Upstream Mesa alone has Turnip-KGSL but its
# gallium loader does not find /dev/kgsl-3d0 inside a Linux container.
#
# STATUS: Turnip-KGSL in proot is well tested by the community. rusticl on
# top of freedreno-kgsl or zink-over-turnip is NOT a tested combination;
# --verify probes every candidate and reports which one exposes cl_khr_fp16.
#
# Usage:
#   chmod +x build_mesa_adreno_rusticl_fp16.sh
#   ./build_mesa_adreno_rusticl_fp16.sh             # full build
#   ./build_mesa_adreno_rusticl_fp16.sh --native    # -mcpu=native
#   ./build_mesa_adreno_rusticl_fp16.sh --verify    # probe only
#   ./build_mesa_adreno_rusticl_fp16.sh --icd-only  # re-register ICDs
#
# Environment overrides:
#   MESA_REF=<tag|branch>   lfdevs tag (default below)
#   JOBS=<n>                parallel jobs (default: half the cores, Android
#                           kills processes aggressively when RAM runs out)
# =============================================================================

set -euo pipefail

# -- Configuration -------------------------------------------------------------
MESA_GIT="https://github.com/lfdevs/mesa-for-android-container.git"
MESA_REF="${MESA_REF:-mesa-26.2.0-devel-20260709}"
MESA_PREFIX="/usr/local/mesa"
BUILD_DIR="/tmp/mesa-adreno-build"
ICD_VENDORS="/etc/OpenCL/vendors"
VK_ICD_DIR="/etc/vulkan/icd.d"
KGSL_NODE="/dev/kgsl-3d0"

NPROC="$(nproc)"
JOBS="${JOBS:-$(( NPROC > 1 ? NPROC / 2 : 1 ))}"

if command -v dpkg-architecture &>/dev/null; then
    LIB_ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
else
    LIB_ARCH="$(uname -m)-linux-gnu"
fi
ARCH="$(uname -m)"
VK_ICD_JSON="${MESA_PREFIX}/share/vulkan/icd.d/freedreno_icd.${ARCH}.json"
MESA_LIBDIR="${MESA_PREFIX}/lib/${LIB_ARCH}"

# rusticl driver names to probe, in order of preference
RUSTICL_CANDIDATES=(freedreno kgsl zink llvmpipe)

if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${CYAN}[adreno-fp16]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
die()  { echo -e "${RED}[ FAIL ]${RESET} $*" >&2; exit 1; }
hr()   { echo -e "${BOLD}------------------------------------------------------${RESET}"; }

# -- Argument parsing ----------------------------------------------------------
MODE="full"
NATIVE_OPT="false"
for arg in "$@"; do
    case "$arg" in
        --verify)   MODE="verify" ;;
        --icd-only) MODE="icd" ;;
        --native)   NATIVE_OPT="true" ;;
        --help|-h)  sed -n '2,36p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "Unknown argument: $arg  (try --help)" ;;
    esac
done

# -- Sanity checks -------------------------------------------------------------
check_env() {
    [ "$(id -u)" -eq 0 ] || die "Run as root (proot-distro login gives you root)."
    [ "$ARCH" = "aarch64" ] || die "This script targets aarch64 (got ${ARCH})."

    if [ -e "${KGSL_NODE}" ]; then
        if [ -r "${KGSL_NODE}" ] && [ -w "${KGSL_NODE}" ]; then
            ok "${KGSL_NODE} present and accessible."
        else
            warn "${KGSL_NODE} exists but is not read/writable - GPU drivers will fail."
        fi
    else
        warn "${KGSL_NODE} not found: not an Adreno device, or /dev is not bound"
        warn "into the container. Only llvmpipe will work."
    fi

    local model
    model=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null || true)
    [ -n "$model" ] && log "GPU model reported by KGSL: ${model}"

    local mem_mb
    mem_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    log "Build jobs: ${JOBS}/${NPROC}  |  MemAvailable: ${mem_mb} MB"
    if [ "$mem_mb" -gt 0 ] && [ "$mem_mb" -lt $(( JOBS * 1500 )) ]; then
        warn "Less than ~1.5 GB per job available; consider JOBS=$(( mem_mb / 1500 > 0 ? mem_mb / 1500 : 1 ))."
    fi
}

# -- Verification --------------------------------------------------------------
verify_opencl() {
    hr
    log "Probing rusticl devices for cl_khr_fp16..."
    command -v clinfo &>/dev/null || { warn "clinfo not installed."; return 0; }

    local found=""
    for drv in "${RUSTICL_CANDIDATES[@]}"; do
        local out
        # RUSTICL_FEATURES=fp16 is harmless where fp16 is already default
        out=$(RUSTICL_ENABLE="$drv" RUSTICL_FEATURES=fp16 \
              MESA_LOADER_DRIVER_OVERRIDE=kgsl \
              VK_ICD_FILENAMES="${VK_ICD_JSON}" \
              LD_LIBRARY_PATH="${MESA_LIBDIR}:${LD_LIBRARY_PATH:-}" \
              timeout 60 clinfo 2>/dev/null || true)
        local name
        name=$(echo "$out" | grep -m1 -E "^\s*Device Name" | sed 's/.*Device Name\s*//' || true)
        if [ -z "$name" ]; then
            log "  RUSTICL_ENABLE=${drv}: no device"
            continue
        fi
        if echo "$out" | grep -q "cl_khr_fp16"; then
            ok "  RUSTICL_ENABLE=${drv}: ${name}  [cl_khr_fp16 YES]"
            [ -z "$found" ] && found="$drv"
        else
            warn "  RUSTICL_ENABLE=${drv}: ${name}  [cl_khr_fp16 no]"
        fi
    done

    if [ -n "$found" ]; then
        ok "Best fp16 rusticl driver: ${found}"
        echo "$found" > "${MESA_PREFIX}/.rusticl_driver" 2>/dev/null || true
    else
        warn "No rusticl device exposed cl_khr_fp16."
    fi
    return 0
}

verify_vulkan() {
    hr
    log "Verifying Turnip (freedreno KGSL) Vulkan..."
    [ -f "${VK_ICD_JSON}" ] || { warn "ICD JSON missing: ${VK_ICD_JSON}"; return 0; }
    ok "Turnip ICD JSON present: ${VK_ICD_JSON}"

    command -v vulkaninfo &>/dev/null || { warn "vulkaninfo not installed."; return 0; }
    local out
    out=$(VK_ICD_FILENAMES="${VK_ICD_JSON}" timeout 60 vulkaninfo --summary 2>/dev/null || true)
    echo "$out" | grep -E "deviceName|driverName|driverInfo|apiVersion" || true
    if echo "$out" | grep -qi "turnip"; then
        ok "Turnip device detected."
        if VK_ICD_FILENAMES="${VK_ICD_JSON}" timeout 60 vulkaninfo 2>/dev/null \
              | grep -qE "shaderFloat16\s*=\s*true"; then
            ok "Vulkan shaderFloat16 supported (fp16 compute path for Vulkan backends)."
        else
            warn "shaderFloat16 not reported."
        fi
    else
        warn "Turnip not confirmed - check ${KGSL_NODE} access and GPU support."
    fi
    return 0
}

# -- Phase 1: Dependencies -----------------------------------------------------
pkg_exists() { apt-cache show "$1" &>/dev/null; }

detect_llvm_version() {
    local ver=""
    if command -v llvm-config &>/dev/null; then
        ver=$(llvm-config --version 2>/dev/null | grep -oP '^\d+' || true)
    fi
    if [ -z "$ver" ]; then
        for v in 22 21 20 19 18 17 16 15; do
            if pkg_exists "llvm-${v}-dev"; then ver="$v"; break; fi
        done
    fi
    [ -n "$ver" ] || die "Could not detect an LLVM version."
    echo "$ver"
}

install_deps() {
    hr
    log "Phase 1/5 - Installing build dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local VER
    VER=$(detect_llvm_version)
    log "Detected LLVM version: ${VER}"

    apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils git cmake \
        meson ninja-build pkg-config \
        python3 python3-mako python3-yaml python3-packaging python3-ply \
        gcc g++ bison flex libelf-dev libudev-dev

    apt-get install -y --no-install-recommends \
        "llvm-${VER}-dev" "libclang-${VER}-dev" "clang-${VER}"
    for p in "libclang-cpp${VER}-dev" "libclang-cpp-${VER}-dev"; do
        pkg_exists "$p" && { apt-get install -y --no-install-recommends "$p"; break; }
    done

    if pkg_exists "llvm-spirv-${VER}"; then
        apt-get install -y --no-install-recommends "llvm-spirv-${VER}"
        [ -f /usr/bin/llvm-spirv ] || ln -sf "/usr/bin/llvm-spirv-${VER}" /usr/bin/llvm-spirv
    fi
    for p in "libllvmspirvlib-${VER}-dev" libllvmspirvlib-dev; do
        pkg_exists "$p" && { apt-get install -y --no-install-recommends "$p"; break; }
    done
    if pkg_exists "libclc-${VER}-dev"; then
        apt-get install -y --no-install-recommends "libclc-${VER}" "libclc-${VER}-dev"
    elif pkg_exists libclc-dev; then
        apt-get install -y --no-install-recommends libclc-dev
    fi

    apt-get install -y --no-install-recommends rustc cargo rustfmt
    for p in bindgen rust-bindgen; do
        pkg_exists "$p" && { apt-get install -y --no-install-recommends "$p"; break; }
    done

    apt-get install -y --no-install-recommends spirv-tools
    for p in spirv-tools-dev spirv-headers libspirv-cross-c-shared-dev; do
        pkg_exists "$p" && apt-get install -y --no-install-recommends "$p"
    done

    # Vulkan: Turnip + zink
    apt-get install -y --no-install-recommends \
        libvulkan-dev libvulkan1 glslang-tools glslang-dev
    for p in vulkan-utility-libraries-dev vulkan-validationlayers-dev; do
        pkg_exists "$p" && { apt-get install -y --no-install-recommends "$p"; break; }
    done
    pkg_exists vulkan-tools && apt-get install -y --no-install-recommends vulkan-tools

    # WSI for Termux:X11 / Wayland presentation
    apt-get install -y --no-install-recommends \
        libwayland-dev wayland-protocols \
        libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev libxrandr-dev \
        libxxf86vm-dev libxcb-dri3-dev libxcb-present-dev libxcb-randr0-dev \
        libxcb-shm0-dev libxcb-sync-dev libxcb-xfixes0-dev libxshmfence-dev

    apt-get install -y --no-install-recommends \
        libdrm-dev libzstd-dev zlib1g-dev libexpat1-dev \
        ocl-icd-opencl-dev clinfo

    rm -rf /var/lib/apt/lists/*
    ok "Dependencies installed."
}

check_llvm_spirv_alignment() {
    local llvm_ver spirv_ver
    llvm_ver=$(llvm-config --version 2>/dev/null | grep -oP '^\d+' || echo "?")
    spirv_ver=$(llvm-spirv --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1 || echo "?")
    if [ "$llvm_ver" = "?" ] || [ "$spirv_ver" = "?" ]; then
        warn "Could not verify LLVM/llvm-spirv alignment - continuing."
        return
    fi
    [ "$llvm_ver" = "$spirv_ver" ] || die "LLVM ${llvm_ver} != llvm-spirv ${spirv_ver}."
    ok "LLVM ${llvm_ver} and llvm-spirv ${spirv_ver} match."
}

# -- Phase 1.5: libclc with FP16 builtins --------------------------------------
build_libclc() {
    hr
    log "Phase 1.5/5 - Building libclc (FP16 builtins)..."
    if [ -f "${MESA_PREFIX}/share/clc/spirv64-mesa3d-.spv" ]; then
        ok "Custom libclc already installed. Skipping."
        return 0
    fi

    local VER src="/tmp/libclc-src"
    VER=$(detect_llvm_version)
    rm -rf "$src"; mkdir -p "$src"; cd "$src"

    git init -q
    git remote add origin https://github.com/llvm/llvm-project.git
    git config core.sparseCheckout true
    echo "libclc/" >> .git/info/sparse-checkout
    if ! git pull -q --depth=1 origin "release/${VER}.x" 2>/dev/null; then
        log "release/${VER}.x not found, using main..."
        git pull -q --depth=1 origin main
    fi

    mkdir -p libclc/build; cd libclc/build

    local LLVM_CFG="/usr/bin/llvm-config-${VER}"
    [ -f "$LLVM_CFG" ] || LLVM_CFG=$(command -v llvm-config)
    local CC_BIN="/usr/bin/clang-${VER}"
    [ -f "$CC_BIN" ] || CC_BIN=$(command -v clang)
    local CXX_BIN="/usr/bin/clang++-${VER}"
    [ -f "$CXX_BIN" ] || CXX_BIN=$(command -v clang++)
    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")

    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${MESA_PREFIX}" \
        -DCMAKE_C_COMPILER="${CC_BIN}" \
        -DCMAKE_CXX_COMPILER="${CXX_BIN}" \
        -DCMAKE_C_FLAGS="--gcc-install-dir=${gcc_dir}" \
        -DCMAKE_CXX_FLAGS="--gcc-install-dir=${gcc_dir}" \
        -DLLVM_CONFIG="${LLVM_CFG}" \
        -DLIBCLC_TARGETS_TO_BUILD="spirv-mesa3d-;spirv64-mesa3d-" \
        ..
    ninja -j"${JOBS}"
    ninja install
    rm -rf "$src"
    ok "Custom libclc installed to ${MESA_PREFIX}"
}

# -- Phase 2: Fetch ------------------------------------------------------------
fetch_mesa() {
    hr
    log "Phase 2/5 - Fetching Mesa (${MESA_REF}) from lfdevs fork..."
    rm -rf "${BUILD_DIR}"
    git clone --depth=1 --branch "${MESA_REF}" "${MESA_GIT}" "${BUILD_DIR}" \
        || die "Clone failed. Check that tag/branch '${MESA_REF}' exists."
    ok "Source ready: $(cat "${BUILD_DIR}/VERSION" 2>/dev/null || echo unknown)"
}

# -- Phase 3: Configure --------------------------------------------------------
configure_mesa() {
    hr
    log "Phase 3/5 - Configuring (Turnip-KGSL + freedreno + zink + rusticl)..."
    cd "${BUILD_DIR}"

    local meson_opts=(
        --prefix="${MESA_PREFIX}"
        --buildtype=release
        -Db_ndebug=true
        # Gallium: freedreno (KGSL) for native rusticl, zink over Turnip,
        # llvmpipe as CPU fallback
        -Dgallium-drivers=freedreno,zink,llvmpipe
        -Dfreedreno-kmds=kgsl
        # Vulkan: Turnip
        -Dvulkan-drivers=freedreno
        -Dvulkan-layers=device-select
        # Presentation to Termux:X11 / Wayland (Vulkan WSI only)
        -Dplatforms=x11,wayland
        -Dglx=disabled
        -Degl=disabled
        -Dgbm=disabled
        -Dgles1=disabled
        -Dgles2=disabled
        -Dopengl=false
        -Dgallium-va=disabled
        # rusticl
        -Dgallium-rusticl=true
        -Dllvm=enabled
        -Dshared-llvm=enabled
        -Drust_std=2021
        # Things that do not exist or help on Android
        -Dvalgrind=disabled
        -Dlibunwind=disabled
        -Dlmsensors=disabled
        -Dandroid-libbacktrace=disabled
        -Dintel-rt=disabled
        -Dmicrosoft-clc=disabled
        -Dbuild-tests=false
    )

    if [ "$NATIVE_OPT" = "true" ]; then
        # -march=native is unreliable on big.LITTLE ARM; -mcpu=native is the ARM idiom
        meson_opts+=("-Dc_args=-mcpu=native" "-Dcpp_args=-mcpu=native")
        log "Native CPU optimization enabled (-mcpu=native)"
    fi

    export PKG_CONFIG_PATH="${MESA_PREFIX}/share/pkgconfig:${MESA_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")
    export BINDGEN_EXTRA_CLANG_ARGS="--gcc-install-dir=${gcc_dir}"

    meson setup builddir "${meson_opts[@]}"
    ok "Configuration complete."
}

# -- Phase 4: Build + install --------------------------------------------------
build_mesa() {
    hr
    log "Phase 4/5 - Building (expect 45-120 min on a phone, jobs=${JOBS})..."
    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")
    export BINDGEN_EXTRA_CLANG_ARGS="--gcc-install-dir=${gcc_dir}"

    ninja -C "${BUILD_DIR}/builddir" -j"${JOBS}"
    ok "Build complete."
    ninja -C "${BUILD_DIR}/builddir" install
    ok "Installed to ${MESA_PREFIX}."
    rm -rf "${BUILD_DIR}"
}

# -- Phase 5: Register ICDs ----------------------------------------------------
register_icd() {
    hr
    log "Phase 5/5 - Registering rusticl OpenCL ICD + Turnip Vulkan ICD..."

    local new_icd="${MESA_PREFIX}/etc/OpenCL/vendors/rusticl.icd"
    local new_so="${MESA_LIBDIR}/libRusticlOpenCL.so.1"
    local cl_link="${ICD_VENDORS}/mesa-adreno-rusticl.icd"
    local old_icd="${ICD_VENDORS}/rusticl.icd"

    [ -f "${new_icd}" ] || die "OpenCL ICD not found: ${new_icd}"
    [ -f "${new_so}"  ] || die "OpenCL library not found: ${new_so}"

    mkdir -p "${ICD_VENDORS}"
    ln -sf "${new_icd}" "${cl_link}"
    ok "Linked OpenCL ICD: ${cl_link}"
    if [ -f "${old_icd}" ] && [ ! -L "${old_icd}" ]; then
        mv "${old_icd}" "${old_icd}.disabled"
        ok "Disabled distro rusticl ICD."
    elif [ -L "${old_icd}" ]; then
        rm -f "${old_icd}"
    fi

    if [ -f "${VK_ICD_JSON}" ]; then
        mkdir -p "${VK_ICD_DIR}"
        ln -sf "${VK_ICD_JSON}" "${VK_ICD_DIR}/mesa-adreno-turnip.json"
        ok "Linked Vulkan ICD: ${VK_ICD_DIR}/mesa-adreno-turnip.json"
    else
        warn "Turnip ICD JSON not found at ${VK_ICD_JSON}."
    fi

    local layer_dir="${MESA_PREFIX}/share/vulkan/implicit_layer.d"
    if [ -d "${layer_dir}" ]; then
        mkdir -p /etc/vulkan/implicit_layer.d
        for j in "${layer_dir}"/*.json; do
            [ -f "$j" ] && ln -sf "$j" "/etc/vulkan/implicit_layer.d/$(basename "$j")"
        done
    fi

    echo "${MESA_LIBDIR}" > /etc/ld.so.conf.d/mesa-adreno.conf
    ldconfig
    ok "ldconfig updated."
}

# -- Runtime hints -------------------------------------------------------------
print_env_hint() {
    local drv
    drv=$(cat "${MESA_PREFIX}/.rusticl_driver" 2>/dev/null || echo "freedreno")
    hr
    cat <<ENV
${BOLD}Runtime environment (add to container ENV or ~/.bashrc):${RESET}

  export LD_LIBRARY_PATH=${MESA_LIBDIR}:\${LD_LIBRARY_PATH}
  export MESA_LOADER_DRIVER_OVERRIDE=kgsl
  export VK_ICD_FILENAMES=${VK_ICD_JSON}
  export RUSTICL_ENABLE=${drv}
  export RUSTICL_FEATURES=fp16

${BOLD}Verify:${RESET}
  clinfo | grep -E "Device Name|cl_khr_fp16"
  vulkaninfo --summary

${BOLD}Precompile Qrack kernels:${RESET}
  RUSTICL_ENABLE=${drv} /usr/local/bin/qrack_cl_precompile

ENV
}

# -- Main ----------------------------------------------------------------------
main() {
    hr
    echo -e "${BOLD}Mesa Adreno (KGSL) rusticl fp16 + Turnip Vulkan builder${RESET}"
    echo -e "Mode: ${YELLOW}${MODE}${RESET}  |  Ref: ${MESA_REF}  |  Prefix: ${MESA_PREFIX}"
    hr
    check_env

    case "$MODE" in
        verify)
            verify_vulkan
            verify_opencl
            ;;
        icd)
            register_icd
            verify_vulkan
            verify_opencl
            print_env_hint
            ;;
        full)
            install_deps
            check_llvm_spirv_alignment
            build_libclc
            fetch_mesa
            configure_mesa
            build_mesa
            register_icd
            verify_vulkan
            verify_opencl
            print_env_hint
            ok "Done."
            ;;
    esac
}

main "$@"
