#!/usr/bin/env bash
# =============================================================================
# build_mesa_rusticl_fp16.sh   (full-feature edition)
#
# Builds Mesa 26.1.4 from source into /usr/local/mesa with the *complete*
# feature set rather than a compute-only slice:
#
#   * rusticl OpenCL ICD with cl_khr_fp16 for vega20 (Radeon Pro VII)
#   * Vulkan: RADV (amd) + lavapipe + anv/hasvk/nvk/virtio where available
#   * OpenGL / GLES1 / GLES2 / GLX(dri) / EGL / GBM
#   * All x86_64 Gallium drivers (radeonsi, r300, r600, nouveau, iris, crocus,
#     i915, svga, virgl, zink, d3d12, llvmpipe, softpipe) - no ARM/SoC targets
#   * Video + state trackers: VA-API, VDPAU, XA, gallium-nine, all video codecs
#   * Vulkan layers (device-select, overlay, screenshot, vram-report-limit, ...)
#
# Unsupported meson options and driver names are probed against the extracted
# tree's meson.options and silently dropped, so this survives Mesa churn.
#
# Run as root (or with sudo) inside the container, or directly on the host.
# Safe to re-run: each phase is idempotent.
#
# Usage:
#   chmod +x build_mesa_rusticl_fp16.sh
#   sudo ./build_mesa_rusticl_fp16.sh                # full-feature build
#   sudo ./build_mesa_rusticl_fp16.sh --native       # + -march=native
#   sudo ./build_mesa_rusticl_fp16.sh --all-drivers  # every driver meson offers
#   sudo ./build_mesa_rusticl_fp16.sh --minimal      # old compute-only config
#   sudo ./build_mesa_rusticl_fp16.sh --glvnd        # build as a glvnd vendor
#   sudo ./build_mesa_rusticl_fp16.sh --system-libs  # register libs w/ ldconfig
#   sudo ./build_mesa_rusticl_fp16.sh --verify       # verify only (no build)
#   sudo ./build_mesa_rusticl_fp16.sh --icd-only     # re-register ICDs only
#   sudo ./build_mesa_rusticl_fp16.sh --jobs 16      # cap parallelism
#
# After success:
#   mesa-env clinfo | grep cl_khr_fp16
#   mesa-env vulkaninfo --summary
#   mesa-env glxinfo -B
#   mesa-env /usr/local/bin/qrack_cl_precompile
# =============================================================================

set -euo pipefail

# -- Configuration -------------------------------------------------------------
MESA_VERSION="26.1.4"
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
MESA_PREFIX="/usr/local/mesa"
BUILD_DIR="/tmp/mesa-build"
TARBALL="/tmp/mesa-${MESA_VERSION}.tar.xz"
ICD_VENDORS="/etc/OpenCL/vendors"
VK_ICD_DIR="/etc/vulkan/icd.d"
VK_LAYER_DIR="/etc/vulkan/explicit_layer.d"
ENV_WRAPPER="/usr/local/bin/mesa-env"

# Dynamically determine the library architecture string (e.g., x86_64-linux-gnu)
if command -v dpkg-architecture &>/dev/null; then
    LIB_ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
else
    LIB_ARCH="$(uname -m)-linux-gnu"
fi
ARCH="$(uname -m)"

# Driver wish-lists (x86_64 desktop/workstation only - no ARM/SoC targets).
# Anything meson does not offer is dropped automatically.
GALLIUM_WANT="radeonsi,r300,r600,nouveau,iris,crocus,i915,svga,virgl,zink,d3d12,llvmpipe,softpipe"
VULKAN_WANT="amd,intel,intel_hasvk,nouveau,swrast,virtio,gfxstream"
VK_LAYERS_WANT="device-select,overlay,screenshot,vram-report-limit,anti-lag,intel-nullhw"
PLATFORMS_WANT="x11,wayland"

# ARM / embedded-SoC drivers. Never built, including under --all-drivers.
ARM_DRIVERS="panfrost panthor lima v3d vc4 freedreno etnaviv tegra asahi kmsro \
broadcom imagination powervr rogue vivante mali midgard bifrost valhall \
nouveau-tegra swr arm"

# Colour helpers - fall back gracefully if not a terminal
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${CYAN}[mesa-full]${RESET} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${RESET} $*"; }
die()  { echo -e "${RED}[ FAIL ]${RESET} $*" >&2; exit 1; }
hr()   { echo -e "${BOLD}------------------------------------------------------${RESET}"; }

# -- Argument parsing ----------------------------------------------------------
MODE="full"
NATIVE_OPT="false"
FEATURES="all"        # all | minimal
ALL_DRIVERS="false"
USE_GLVND="false"
SYSTEM_LIBS="false"
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
    case "$1" in
        --verify)      MODE="verify" ;;
        --icd-only)    MODE="icd" ;;
        --native)      NATIVE_OPT="true" ;;
        --minimal)     FEATURES="minimal" ;;
        --all-drivers) ALL_DRIVERS="true" ;;
        --glvnd)       USE_GLVND="true" ;;
        --system-libs) SYSTEM_LIBS="true" ;;
        --jobs)        shift; JOBS="${1:?--jobs needs a number}" ;;
        --jobs=*)      JOBS="${1#*=}" ;;
        --help|-h)
            sed -n '2,40p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown argument: $1  (try --help)" ;;
    esac
    shift
done

# -- Sanity checks -------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)."
    fi
}

check_arch() {
    case "$ARCH" in
        x86_64) ok "Host architecture: ${ARCH}" ;;
        *) die "This script targets x86_64 only (host is ${ARCH}). ARM/SoC drivers are deliberately not supported." ;;
    esac
}

mesa_env_exports() {
    cat <<ENVBLOCK
export RUSTICL_ENABLE=\${RUSTICL_ENABLE:-radeonsi}
export DRI_PRIME=\${DRI_PRIME:-0}
export LD_LIBRARY_PATH=${MESA_PREFIX}/lib/${LIB_ARCH}:\${LD_LIBRARY_PATH:-}
export LIBGL_DRIVERS_PATH=${MESA_PREFIX}/lib/${LIB_ARCH}/dri
export LIBVA_DRIVERS_PATH=${MESA_PREFIX}/lib/${LIB_ARCH}/dri
export VDPAU_DRIVER_PATH=${MESA_PREFIX}/lib/${LIB_ARCH}/vdpau
export OCL_ICD_VENDORS=\${OCL_ICD_VENDORS:-${ICD_VENDORS}}
ENVBLOCK
}

# -- Verification --------------------------------------------------------------
verify_fp16() {
    hr
    log "Verifying cl_khr_fp16 availability..."
    if ! command -v clinfo &>/dev/null; then
        warn "clinfo not found - install the clinfo package."
        return 0
    fi

    local output
    output=$( eval "$(mesa_env_exports)"; clinfo 2>/dev/null || true )
    echo "$output" | grep -E "Device Name|Driver Version|cl_khr_fp16|Half-precision" || true

    if echo "$output" | grep -q "cl_khr_fp16"; then
        ok "cl_khr_fp16 is present - Mesa rusticl fp16 is working!"
    else
        warn "cl_khr_fp16 not found in clinfo output."
        warn "Check RUSTICL_ENABLE / DRI_PRIME and that libclc built with fp16 builtins."
    fi
    return 0
}

verify_vulkan() {
    hr
    log "Verifying Vulkan ICDs..."

    local icd_dir="${MESA_PREFIX}/share/vulkan/icd.d"
    if [ ! -d "${icd_dir}" ]; then
        warn "No Vulkan ICD directory at ${icd_dir} - Vulkan may not have been built."
        return 0
    fi

    local found=0 json
    for json in "${icd_dir}"/*.json; do
        [ -f "$json" ] || continue
        ok "Vulkan ICD present: $(basename "$json")"
        found=1
    done
    [ "$found" -eq 1 ] || { warn "No ICD JSONs found."; return 0; }

    if command -v vulkaninfo &>/dev/null; then
        local list vk_out
        list=$(printf '%s:' "${icd_dir}"/*.json); list="${list%:}"
        vk_out=$( eval "$(mesa_env_exports)"; VK_ICD_FILENAMES="$list" vulkaninfo --summary 2>/dev/null || true )
        echo "$vk_out" | grep -E "GPU|driverName|driverInfo|apiVersion" || true
        if echo "$vk_out" | grep -qi "radv\|radeon\|lavapipe"; then
            ok "Mesa Vulkan device detected."
        else
            warn "No Mesa Vulkan device confirmed. Check render node permissions / DRI_PRIME."
        fi
    else
        warn "vulkaninfo not installed (apt install vulkan-tools). Skipping live check."
    fi
    return 0
}

verify_gl() {
    hr
    log "Verifying OpenGL / EGL / GBM / video stack..."

    local libdir="${MESA_PREFIX}/lib/${LIB_ARCH}"
    local f
    for f in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libgbm.so.1 libOSMesa.so.8 libxatracker.so.2; do
        if [ -e "${libdir}/${f}" ]; then
            ok "present: ${f}"
        else
            log "absent : ${f}"
        fi
    done

    if [ -d "${libdir}/dri" ]; then
        ok "DRI/VA driver dir: ${libdir}/dri ($(ls -1 "${libdir}/dri" 2>/dev/null | wc -l) entries)"
    fi
    if [ -d "${libdir}/vdpau" ]; then
        ok "VDPAU driver dir: ${libdir}/vdpau ($(ls -1 "${libdir}/vdpau" 2>/dev/null | wc -l) entries)"
    fi
    if [ -d "${libdir}/d3d" ]; then
        ok "gallium-nine dir: ${libdir}/d3d"
    fi

    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v glxinfo &>/dev/null; then
        ( eval "$(mesa_env_exports)"; glxinfo -B 2>/dev/null | grep -E "OpenGL renderer|OpenGL version|Device:" ) || true
    else
        log "No DISPLAY/WAYLAND_DISPLAY (or glxinfo missing) - skipping live GL query."
        log "Headless check: mesa-env env LIBGL_ALWAYS_SOFTWARE=1 glxinfo -B"
    fi

    if command -v vainfo &>/dev/null; then
        ( eval "$(mesa_env_exports)"; vainfo 2>/dev/null | head -20 ) || true
    fi
    return 0
}

# -- Phase 1: Dependencies -----------------------------------------------------
detect_llvm_version() {
    local ver=""
    if command -v llvm-config &>/dev/null; then
        ver=$(llvm-config --version 2>/dev/null | grep -oP '^\d+' || true)
    fi

    if [ -z "$ver" ]; then
        for v in 22 21 20 19 18 17 16 15; do
            if apt-cache show "llvm-${v}-dev" &>/dev/null 2>&1; then
                ver="$v"
                break
            fi
        done
    fi

    [ -n "$ver" ] || die "Could not detect an LLVM version. Install llvm-XX-dev manually."
    echo "$ver"
}

# pkg_exists <name>
# True only if apt has an *installable candidate*. `apt-cache show` is not
# enough: obsoleted packages such as vulkan-validationlayers-dev still have a
# record (referred to by their replacement) but no installation candidate, and
# apt-get then exits 100 and kills the build under `set -e`.
pkg_exists() {
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2; exit}')
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# apt_require <pkgs...>  - hard failure if any of these cannot be installed
apt_require() {
    apt-get install -y --no-install-recommends "$@" \
        || die "Required packages failed to install: $*"
}

# apt_optional <pkgs...> - best effort, NEVER fatal.
# Filters to packages with a real candidate, tries them as one transaction, and
# falls back to one-by-one so a single bad package cannot take out the rest.
apt_optional() {
    local p want=()
    for p in "$@"; do
        if pkg_exists "$p"; then
            want+=("$p")
        else
            log "optional package has no installation candidate, skipping: $p"
        fi
    done
    [ ${#want[@]} -gt 0 ] || return 0

    if apt-get install -y --no-install-recommends "${want[@]}" 2>/dev/null; then
        return 0
    fi

    warn "Batch install failed; retrying optional packages individually..."
    for p in "${want[@]}"; do
        if apt-get install -y --no-install-recommends "$p" 2>/dev/null; then
            ok "optional: $p"
        else
            warn "optional package could not be installed, continuing without it: $p"
        fi
    done
    return 0
}

# apt_first <pkgs...> - install the first one that has a candidate, else skip
apt_first() {
    local p
    for p in "$@"; do
        if pkg_exists "$p" && apt-get install -y --no-install-recommends "$p" 2>/dev/null; then
            ok "selected: $p"
            return 0
        fi
    done
    log "none of these are available, skipping: $*"
    return 0
}

install_deps() {
    hr
    log "Phase 1/5 - Installing build dependencies (feature set: ${FEATURES})..."

    apt-get update -qq

    local VER
    VER=$(detect_llvm_version)
    log "Detected LLVM version: ${VER}"

    # -- Core build tools ------------------------------------------------------
    apt_require \
        curl ca-certificates xz-utils git cmake \
        meson ninja-build pkg-config \
        python3 python3-mako python3-yaml \
        gcc g++ bison flex libelf-dev

    apt_optional python3-ply python3-packaging python3-pycparser

    # -- LLVM / Clang ----------------------------------------------------------
    apt_require \
        "llvm-${VER}-dev" \
        "libclang-${VER}-dev" \
        "clang-${VER}"

    apt_first "libclang-cpp${VER}-dev" "libclang-cpp-${VER}-dev"

    # -- SPIRV-LLVM-Translator -------------------------------------------------
    apt_optional "llvm-spirv-${VER}"
    if [ ! -f /usr/bin/llvm-spirv ] && [ -f "/usr/bin/llvm-spirv-${VER}" ]; then
        ln -sf "/usr/bin/llvm-spirv-${VER}" /usr/bin/llvm-spirv
        ok "Linked /usr/bin/llvm-spirv -> llvm-spirv-${VER}"
    fi

    apt_first "libllvmspirvlib-${VER}-dev" "libllvmspirvlib-dev"

    # -- libclc (kept to satisfy package trees, overridden by build_libclc) ---
    if pkg_exists "libclc-${VER}-dev"; then
        apt_optional "libclc-${VER}" "libclc-${VER}-dev"
    else
        apt_optional libclc-dev
    fi

    # -- Rust ------------------------------------------------------------------
    apt_require rustc cargo rustfmt
    apt_optional bindgen rust-bindgen

    # -- SPIR-V tools ----------------------------------------------------------
    apt_require spirv-tools
    apt_optional spirv-tools-dev spirv-headers libspirv-cross-c-shared-dev

    # -- Vulkan ----------------------------------------------------------------
    log "Installing Vulkan build dependencies..."
    apt_require libvulkan-dev glslang-tools
    apt_optional glslang-dev libvulkan1 vulkan-tools
    # vulkan-utility-libraries-dev REPLACES vulkan-validationlayers-dev on
    # Ubuntu 25.x/26.04 - the old name still has an apt record but no candidate,
    # so it must be an either/or, never both.
    apt_first vulkan-utility-libraries-dev vulkan-validationlayers-dev

    # -- X11 / XCB / Wayland (needed once GLX+EGL+GBM are enabled) -------------
    log "Installing windowing-system dependencies..."
    apt_require \
        libx11-dev libx11-xcb-dev libxext-dev libxfixes-dev libxdamage-dev \
        libxshmfence-dev libxxf86vm-dev libxrandr-dev libxrender-dev \
        libxcb1-dev libxcb-glx0-dev libxcb-dri2-0-dev libxcb-dri3-dev \
        libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev libxcb-shm0-dev \
        libxcb-xfixes0-dev \
        libwayland-dev wayland-protocols

    apt_optional libxcb-keysyms1-dev libwayland-egl-backend-dev libwayland-bin \
                 libxcb-composite0-dev libxcb-util-dev

    # -- Video / state trackers ------------------------------------------------
    if [ "$FEATURES" = "all" ]; then
        log "Installing video and state-tracker dependencies..."
        apt_optional libva-dev libvdpau-dev vainfo vdpauinfo \
                     directx-headers-dev libsensors-dev libunwind-dev \
                     mesa-utils
        if [ "$USE_GLVND" = "true" ]; then
            apt_optional libglvnd-dev libglvnd-core-dev
        fi
    fi

    # -- DRM + misc ------------------------------------------------------------
    apt_require \
        libdrm-dev libudev-dev \
        libzstd-dev zlib1g-dev libexpat1-dev \
        ocl-icd-opencl-dev \
        clinfo

    rm -rf /var/lib/apt/lists/*
    ok "All dependencies installed."
}

check_llvm_spirv_alignment() {
    local llvm_ver spirv_ver
    llvm_ver=$(llvm-config --version 2>/dev/null | grep -oP '^\d+' || echo "?")
    spirv_ver=$(llvm-spirv --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1 || echo "?")

    if [ "$llvm_ver" = "?" ] || [ "$spirv_ver" = "?" ]; then
        warn "Could not verify LLVM/spirv-translator version alignment - continuing anyway."
        return
    fi
    if [ "$llvm_ver" != "$spirv_ver" ]; then
        die "LLVM major (${llvm_ver}) != llvm-spirv major (${spirv_ver}). Install matching llvm-spirv-${llvm_ver} and retry."
    fi
    ok "LLVM ${llvm_ver} and llvm-spirv ${spirv_ver} major versions match."
}

check_libdrm_version() {
    # A full-driver build raises the libdrm floor well above a compute-only one.
    local have want
    have=$(pkg-config --modversion libdrm 2>/dev/null || echo "0")
    want=$(grep -hoP "libdrm'\s*,\s*version\s*:\s*'>=\s*\K[0-9.]+" \
             "${BUILD_DIR}/meson.build" 2>/dev/null | sort -V | tail -1 || true)
    [ -n "$want" ] || want=$(grep -hoP "_drm_ver\s*=\s*'\K[0-9.]+" "${BUILD_DIR}/meson.build" 2>/dev/null | head -1 || true)

    if [ -z "$want" ]; then
        log "System libdrm: ${have} (could not determine Mesa's requirement)."
        return 0
    fi
    if [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -1)" != "$want" ]; then
        warn "System libdrm ${have} is older than Mesa's requirement ${want}."
        warn "Build libdrm from https://dri.freedesktop.org/libdrm/ into ${MESA_PREFIX}"
        warn "and re-run with PKG_CONFIG_PATH pointing at it, or drop drivers that need it."
    else
        ok "libdrm ${have} satisfies Mesa's requirement (>= ${want})."
    fi
}

# -- Phase 1.5: Build Custom libclc --------------------------------------------
build_libclc() {
    hr
    log "Phase 1.5/5 - Building libclc from source (fixing Ubuntu's missing FP16 builtins)..."

    if [ -f "${MESA_PREFIX}/share/clc/spirv64-mesa3d-.spv" ]; then
        ok "Custom libclc already installed. Skipping."
        return 0
    fi

    local VER
    VER=$(detect_llvm_version)
    local LIBCLC_SRC="/tmp/libclc-src"

    rm -rf "${LIBCLC_SRC}"
    mkdir -p "${LIBCLC_SRC}"
    cd "${LIBCLC_SRC}"

    log "Cloning libclc from llvm-project via sparse-checkout..."
    git init -q
    git remote add origin https://github.com/llvm/llvm-project.git
    git config core.sparseCheckout true
    echo "libclc/" >> .git/info/sparse-checkout

    if ! git pull -q --depth=1 origin "release/${VER}.x" 2>/dev/null; then
        log "Branch release/${VER}.x not found, falling back to main..."
        git pull -q --depth=1 origin main
    fi

    cd libclc
    mkdir build
    cd build

    local LLVM_CFG="/usr/bin/llvm-config-${VER}"
    if [ ! -f "$LLVM_CFG" ]; then
        LLVM_CFG=$(command -v llvm-config || true)
    fi

    local CLANG_C="/usr/bin/clang-${VER}"
    if [ ! -f "$CLANG_C" ]; then
        CLANG_C=$(command -v clang || true)
    fi

    local CLANG_CXX="/usr/bin/clang++-${VER}"
    if [ ! -f "$CLANG_CXX" ]; then
        CLANG_CXX=$(command -v clang++ || true)
    fi

    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")

    # Build the full target set so nouveau/clover-style consumers work too.
    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${MESA_PREFIX}" \
        -DCMAKE_CXX_COMPILER="${CLANG_CXX}" \
        -DCMAKE_C_COMPILER="${CLANG_C}" \
        -DCMAKE_CXX_FLAGS="--gcc-install-dir=${gcc_dir}" \
        -DCMAKE_C_FLAGS="--gcc-install-dir=${gcc_dir}" \
        -DLLVM_CONFIG="${LLVM_CFG}" \
        -DLIBCLC_TARGETS_TO_BUILD="spirv-mesa3d-;spirv64-mesa3d-" \
        ..

    ninja -j"${JOBS}"
    ninja install
    ok "Custom libclc installed to ${MESA_PREFIX}"
}

# -- Phase 2: Fetch ------------------------------------------------------------
# NOTE: checksum pinning has been removed. The tarball is accepted on the basis
# of TLS to archive.mesa3d.org plus an xz integrity test only.
fetch_mesa() {
    hr
    log "Phase 2/5 - Fetching Mesa ${MESA_VERSION}..."

    if [ -f "${TARBALL}" ]; then
        log "Tarball already present - testing archive integrity..."
        if xz -t "${TARBALL}" &>/dev/null; then
            ok "Cached tarball is a readable xz archive - reusing."
            return 0
        else
            warn "Cached tarball is truncated or corrupt - re-downloading."
            rm -f "${TARBALL}"
        fi
    fi

    curl -fsSL --progress-bar "${MESA_URL}" -o "${TARBALL}" \
        || die "Download failed from ${MESA_URL}"
    xz -t "${TARBALL}" \
        || die "Downloaded file is not a valid xz archive - transfer likely truncated."
    ok "Mesa ${MESA_VERSION} downloaded."
}

# -- meson option introspection ------------------------------------------------
# Everything below is driven by the *extracted source tree*, so options and
# driver names that this Mesa release does not know about are dropped instead
# of blowing up `meson setup`.
MESA_OPT_FILE=""

locate_opt_file() {
    local f
    for f in "${BUILD_DIR}/meson.options" "${BUILD_DIR}/meson_options.txt"; do
        [ -f "$f" ] && { MESA_OPT_FILE="$f"; return 0; }
    done
    warn "No meson.options found - option filtering disabled."
    return 0
}

opt_exists() {
    [ -n "${MESA_OPT_FILE}" ] || return 0
    grep -qE "option\(\s*'$1'" "${MESA_OPT_FILE}"
}

opt_choices() {
    [ -n "${MESA_OPT_FILE}" ] || return 1
    python3 - "$1" "${MESA_OPT_FILE}" <<'PYEOF'
import re, sys
name, path = sys.argv[1], sys.argv[2]
src = open(path, encoding='utf-8', errors='replace').read()
m = re.search(r"option\(\s*'" + re.escape(name) + r"'", src)
if not m:
    sys.exit(1)
i = src.index('(', m.start())
depth = 0
end = len(src)
for j in range(i, len(src)):
    c = src[j]
    if c == '(':
        depth += 1
    elif c == ')':
        depth -= 1
        if depth == 0:
            end = j
            break
block = src[i:end]
cm = re.search(r"choices\s*:\s*\[(.*?)\]", block, re.S)
if not cm:
    sys.exit(1)
for v in re.findall(r"'([^']*)'", cm.group(1)):
    print(v)
PYEOF
}

# add_opt -Dname=value  -> appended only if the option exists in this Mesa
add_opt() {
    local kv="${1#-D}" name
    name="${kv%%=*}"
    if opt_exists "$name"; then
        meson_opts+=("$1")
    else
        log "option not offered by Mesa ${MESA_VERSION}, skipping: ${name}"
    fi
}

# filter_values <option> <comma-list>  -> comma-list intersected with choices
filter_values() {
    local name="$1" want="$2" avail out=() v dropped=()
    avail=$(opt_choices "$name" 2>/dev/null || true)
    if [ -z "$avail" ]; then
        echo "$want"
        return 0
    fi
    local IFS=','
    read -ra want_arr <<<"$want"
    unset IFS
    for v in "${want_arr[@]}"; do
        if grep -qx -- "$v" <<<"$avail"; then out+=("$v"); else dropped+=("$v"); fi
    done
    [ ${#dropped[@]} -eq 0 ] || log "unsupported ${name} values dropped: ${dropped[*]}"
    ( IFS=','; echo "${out[*]}" )
}

# all_values <option> [exclusions...] -> every choice meson offers
all_values() {
    local name="$1"; shift
    local avail out=() v skip
    avail=$(opt_choices "$name" 2>/dev/null || true)
    [ -n "$avail" ] || return 1
    while IFS= read -r v; do
        [ -n "$v" ] || continue
        skip="no"
        for x in "$@"; do [ "$v" = "$x" ] && skip="yes"; done
        [ "$skip" = "yes" ] || out+=("$v")
    done <<<"$avail"
    ( IFS=','; echo "${out[*]}" )
}

# -- Phase 3: Extract + configure ----------------------------------------------
configure_mesa() {
    hr
    log "Phase 3/5 - Configuring Mesa..."

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    tar -xJ -C "${BUILD_DIR}" --strip-components=1 -f "${TARBALL}"

    cd "${BUILD_DIR}"
    locate_opt_file
    check_libdrm_version

    local meson_opts=(
        --prefix="${MESA_PREFIX}"
        --buildtype=release
        -Db_ndebug=true
    )

    # ---- driver selection (x86_64 only; ARM/SoC drivers never built) ---------
    local gallium vulkan platforms layers codecs
    gallium="$GALLIUM_WANT"
    vulkan="$VULKAN_WANT"

    if [ "$FEATURES" = "minimal" ]; then
        gallium="radeonsi,llvmpipe,softpipe"
        vulkan="amd"
    elif [ "$ALL_DRIVERS" = "true" ]; then
        # "all" still means "all x86 drivers" - ARM/SoC targets stay excluded.
        gallium=$(all_values gallium-drivers auto ${ARM_DRIVERS} || echo "$gallium")
        vulkan=$(all_values vulkan-drivers auto ${ARM_DRIVERS} || echo "$vulkan")
        log "--all-drivers: every x86_64 driver this Mesa offers (ARM/SoC excluded)."
    fi

    gallium=$(filter_values gallium-drivers "$gallium")
    vulkan=$(filter_values vulkan-drivers "$vulkan")
    platforms=$(filter_values platforms "$PLATFORMS_WANT")
    layers=$(filter_values vulkan-layers "$VK_LAYERS_WANT")

    [ -n "$gallium" ] || die "No usable gallium drivers left after filtering."
    log "gallium-drivers : ${gallium}"
    log "vulkan-drivers  : ${vulkan:-<none>}"
    log "platforms       : ${platforms:-<none>}"

    add_opt "-Dgallium-drivers=${gallium}"
    [ -n "$vulkan" ]   && add_opt "-Dvulkan-drivers=${vulkan}"
    [ -n "$platforms" ] && add_opt "-Dplatforms=${platforms}"
    [ -n "$layers" ]   && add_opt "-Dvulkan-layers=${layers}"

    # ---- rusticl / OpenCL (the point of the exercise) ------------------------
    add_opt "-Dgallium-rusticl=true"
    add_opt "-Dopencl-spirv=true"
    add_opt "-Dllvm=enabled"
    add_opt "-Dshared-llvm=enabled"
    add_opt "-Drust_std=2021"

    if [ "$FEATURES" = "minimal" ]; then
        # ---- old compute-only behaviour --------------------------------------
        add_opt "-Dglx=disabled"
        add_opt "-Degl=disabled"
        add_opt "-Dgbm=disabled"
        add_opt "-Dgles1=disabled"
        add_opt "-Dgles2=disabled"
        add_opt "-Dopengl=false"
    else
        # ---- full graphics stack ---------------------------------------------
        add_opt "-Dopengl=true"
        add_opt "-Dgles1=enabled"
        add_opt "-Dgles2=enabled"
        add_opt "-Degl=enabled"
        add_opt "-Dgbm=enabled"
        add_opt "-Dosmesa=true"
        add_opt "-Dshared-glapi=enabled"
        if [ -n "$platforms" ] && grep -q "x11" <<<"$platforms"; then
            add_opt "-Dglx=dri"
            add_opt "-Dxlib-lease=enabled"
            add_opt "-Dglx-direct=true"
        else
            add_opt "-Dglx=disabled"
        fi

        if [ "$USE_GLVND" = "true" ]; then
            add_opt "-Dglvnd=enabled"
        else
            add_opt "-Dglvnd=disabled"
        fi

        # ---- video + state trackers -----------------------------------------
        add_opt "-Dgallium-va=enabled"
        add_opt "-Dgallium-vdpau=enabled"
        add_opt "-Dgallium-xa=enabled"
        add_opt "-Dgallium-nine=true"
        add_opt "-Dgallium-extra-hud=true"
        add_opt "-Dgallium-opencl=disabled"   # clover is dead; rusticl replaces it

        codecs=$(filter_values video-codecs "all")
        if [ -z "$codecs" ]; then
            codecs=$(all_values video-codecs || true)
        fi
        [ -n "$codecs" ] && add_opt "-Dvideo-codecs=${codecs}"

        # ---- runtime niceties ------------------------------------------------
        add_opt "-Dshader-cache=enabled"
        add_opt "-Dzstd=enabled"
        add_opt "-Dlmsensors=enabled"
        add_opt "-Dlibunwind=enabled"
        add_opt "-Ddraw-use-llvm=true"
        add_opt "-Dgallium-d3d12-video=enabled"
        add_opt "-Dintel-rt=enabled"
        add_opt "-Dintel-clc=auto"
        add_opt "-Dmicrosoft-clc=disabled"
        add_opt "-Dvalgrind=disabled"
    fi

    if [ "$NATIVE_OPT" = "true" ]; then
        meson_opts+=("-Dc_args=-march=native" "-Dcpp_args=-march=native")
        log "Native CPU optimization enabled (-march=native)"
    fi

    export PKG_CONFIG_PATH="${MESA_PREFIX}/share/pkgconfig:${MESA_PREFIX}/lib/pkgconfig:${MESA_PREFIX}/lib/${LIB_ARCH}/pkgconfig:${PKG_CONFIG_PATH:-}"

    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")
    export BINDGEN_EXTRA_CLANG_ARGS="--gcc-install-dir=${gcc_dir}"

    log "meson setup arguments:"
    printf '    %s\n' "${meson_opts[@]}"

    meson setup builddir "${meson_opts[@]}"
    ok "Configuration complete."
}

# -- Phase 4: Build + install --------------------------------------------------
build_mesa() {
    hr
    log "Phase 4/5 - Building Mesa (full feature set takes ~25-60 min at -j${JOBS})..."

    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")
    export BINDGEN_EXTRA_CLANG_ARGS="--gcc-install-dir=${gcc_dir}"

    ninja -C "${BUILD_DIR}/builddir" -j"${JOBS}"
    ok "Build complete."

    log "Installing to ${MESA_PREFIX}..."
    ninja -C "${BUILD_DIR}/builddir" install
    ok "Install complete."

    log "Cleaning build tree..."
    rm -rf "${BUILD_DIR}" "${TARBALL}"
    ok "Build tree removed."
}

# -- Phase 5: Register ICDs (OpenCL + Vulkan) ----------------------------------
register_opencl_icd() {
    local new_so="${MESA_PREFIX}/lib/${LIB_ARCH}/libRusticlOpenCL.so.1"
    local cl_icd="${ICD_VENDORS}/mesa-${MESA_VERSION%%.*}-rusticl.icd"
    local old_icd="${ICD_VENDORS}/rusticl.icd"
    local old_disabled="${ICD_VENDORS}/rusticl.icd.disabled"

    [ -f "${new_so}" ] || die "Expected OpenCL shared lib not found: ${new_so}"

    mkdir -p "${ICD_VENDORS}"
    # Absolute path in the ICD means the loader finds it without ldconfig.
    echo "${new_so}" > "${cl_icd}"
    ok "Registered OpenCL ICD: ${cl_icd} -> ${new_so}"

    if [ -f "${old_icd}" ] && [ ! -L "${old_icd}" ]; then
        mv "${old_icd}" "${old_disabled}"
        ok "Disabled old ICD: ${old_icd} -> ${old_disabled}"
    elif [ -L "${old_icd}" ]; then
        rm -f "${old_icd}"
        ok "Removed stale symlink: ${old_icd}"
    fi

    # Retire the ICD symlink from previous versions of this script.
    local legacy="${ICD_VENDORS}/mesa-261-rusticl.icd"
    if [ -L "${legacy}" ] && [ "${legacy}" != "${cl_icd}" ]; then
        rm -f "${legacy}"
        ok "Removed legacy ICD symlink: ${legacy}"
    fi
}

register_vulkan_icds() {
    local icd_dir="${MESA_PREFIX}/share/vulkan/icd.d"
    if [ ! -d "${icd_dir}" ]; then
        warn "No Vulkan ICDs to register (${icd_dir} missing)."
        return 0
    fi

    mkdir -p "${VK_ICD_DIR}"
    local json base
    for json in "${icd_dir}"/*.json; do
        [ -f "$json" ] || continue
        base=$(basename "$json")
        ln -sf "${json}" "${VK_ICD_DIR}/mesa-${MESA_VERSION%%.*}-${base}"
        ok "Linked Vulkan ICD: mesa-${MESA_VERSION%%.*}-${base}"
    done

    local layer_dir="${MESA_PREFIX}/share/vulkan/explicit_layer.d"
    if [ -d "${layer_dir}" ]; then
        mkdir -p "${VK_LAYER_DIR}"
        for json in "${layer_dir}"/*.json; do
            [ -f "$json" ] || continue
            ln -sf "${json}" "${VK_LAYER_DIR}/$(basename "$json")"
            ok "Linked Vulkan layer: $(basename "$json")"
        done
    fi
}

register_ldconfig() {
    local conf="/etc/ld.so.conf.d/mesa-rusticl.conf"
    local libdir="${MESA_PREFIX}/lib/${LIB_ARCH}"

    if [ "$SYSTEM_LIBS" = "true" ]; then
        warn "--system-libs: putting ${libdir} on the global loader path."
        warn "In a full-feature build this dir contains libGL/libEGL/libgbm and"
        warn "will therefore override the distro Mesa for EVERY process."
        echo "${libdir}" > "${conf}"
        ldconfig
        ok "ldconfig updated (${conf})."
        return 0
    fi

    if [ -f "${conf}" ]; then
        warn "Found ${conf} from a previous run."
        if [ "$FEATURES" = "all" ] && [ -e "${libdir}/libGL.so.1" ]; then
            warn "This build ships libGL/libEGL in ${libdir}, so that file now"
            warn "silently replaces your system GL stack. Remove it unless you"
            warn "want that:  rm ${conf} && ldconfig"
        fi
    else
        log "Not touching ldconfig. Use ${ENV_WRAPPER} (or LD_LIBRARY_PATH) to"
        log "scope this Mesa to the processes that should see it."
    fi
}

install_env_wrapper() {
    {
        echo "#!/usr/bin/env bash"
        echo "# Generated by build_mesa_rusticl_fp16.sh - scopes Mesa ${MESA_VERSION} to one process."
        echo "set -euo pipefail"
        mesa_env_exports
        local icd_dir="${MESA_PREFIX}/share/vulkan/icd.d"
        if [ -d "${icd_dir}" ]; then
            local list
            list=$(printf '%s:' "${icd_dir}"/*.json); list="${list%:}"
            echo "export VK_ICD_FILENAMES=\${VK_ICD_FILENAMES:-${list}}"
        fi
        echo 'if [ $# -eq 0 ]; then env | grep -E "RUSTICL|DRI_PRIME|LD_LIBRARY_PATH|LIBGL|LIBVA|VDPAU|VK_ICD|OCL_ICD"; exit 0; fi'
        echo 'exec "$@"'
    } > "${ENV_WRAPPER}"
    chmod +x "${ENV_WRAPPER}"
    ok "Installed environment wrapper: ${ENV_WRAPPER} (usage: mesa-env clinfo)"
}

register_icd() {
    hr
    log "Phase 5/5 - Registering OpenCL + Vulkan ICDs and runtime environment..."
    register_opencl_icd
    register_vulkan_icds
    register_ldconfig
    install_env_wrapper
}

# -- Runtime environment hint --------------------------------------------------
print_env_hint() {
    hr
    cat <<ENV
${BOLD}Scoped usage (recommended - no impact on the system GL stack):${RESET}

  mesa-env clinfo | grep -E "cl_khr_fp16|Half-precision"
  mesa-env vulkaninfo --summary
  mesa-env glxinfo -B
  mesa-env vainfo
  mesa-env /usr/local/bin/qrack_cl_precompile

${BOLD}Or export manually (container ENV / ~/.bashrc):${RESET}

$(mesa_env_exports | sed 's/^/  /')
  export VK_ICD_FILENAMES=${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.${ARCH}.json

${BOLD}Rebuild variants:${RESET}
  --minimal      compute-only (rusticl + radeonsi + RADV, no GL)
  --all-drivers  every gallium/vulkan driver this Mesa offers
  --glvnd        build as a libglvnd vendor instead of standalone libGL
  --system-libs  register ${MESA_PREFIX}/lib/${LIB_ARCH} with ldconfig

ENV
}

# -- Main ----------------------------------------------------------------------
main() {
    hr
    echo -e "${BOLD}Mesa ${MESA_VERSION} full-stack builder (rusticl fp16 + GL/GLES/EGL/Vulkan/video)${RESET}"
    echo -e "Mode: ${YELLOW}${MODE}${RESET}  |  Features: ${YELLOW}${FEATURES}${RESET}  |  Prefix: ${MESA_PREFIX}  |  -j${JOBS}  |  $(date)"
    hr

    check_root
    check_arch

    case "$MODE" in
        verify)
            verify_fp16
            verify_vulkan
            [ "$FEATURES" = "all" ] && verify_gl
            ;;
        icd)
            register_icd
            verify_fp16
            verify_vulkan
            [ "$FEATURES" = "all" ] && verify_gl
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
            verify_fp16
            verify_vulkan
            [ "$FEATURES" = "all" ] && verify_gl
            print_env_hint
            ok "All done. Mesa ${MESA_VERSION} installed with the full feature set."
            ;;
    esac
}

main "$@"
