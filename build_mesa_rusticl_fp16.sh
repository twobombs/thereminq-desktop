#!/usr/bin/env bash
# =============================================================================
# build_mesa_rusticl_fp16.sh
#
# Builds Mesa 26.1.4 rusticl OpenCL ICD + Vulkan (radeon/amdvlk via RADV)
# from source and installs it to /usr/local/mesa, enabling cl_khr_fp16 for
# vega20 (Radeon Pro VII) under rusticl on Ubuntu 24.04 / 25.x / 26.04.
#
# Run as root (or with sudo) inside the container, or directly on the host.
# Safe to re-run: each phase is idempotent.
#
# Usage:
#   chmod +x build_mesa_rusticl_fp16.sh
#   sudo ./build_mesa_rusticl_fp16.sh            # full build
#   sudo ./build_mesa_rusticl_fp16.sh --native   # full build optimized for host CPU
#   sudo ./build_mesa_rusticl_fp16.sh --verify   # verify only (no build)
#   sudo ./build_mesa_rusticl_fp16.sh --icd-only # re-register ICD only
#
# After success:
#   RUSTICL_ENABLE=radeonsi clinfo | grep cl_khr_fp16
#   RUSTICL_ENABLE=radeonsi DRI_PRIME=0 /usr/local/bin/qrack_cl_precompile
#   VK_ICD_FILENAMES=/usr/local/mesa/share/vulkan/icd.d/radeon_icd.x86_64.json vulkaninfo
# =============================================================================

set -euo pipefail

# -- Configuration -------------------------------------------------------------
MESA_VERSION="26.1.4"
MESA_SHA256="072705caa9adf4740f1489194b13e278ad959166863b5271fe423a86353c9ab6"
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
MESA_PREFIX="/usr/local/mesa"
BUILD_DIR="/tmp/mesa-build"
TARBALL="/tmp/mesa-${MESA_VERSION}.tar.xz"
ICD_VENDORS="/etc/OpenCL/vendors"
VK_ICD_DIR="/etc/vulkan/icd.d"

# Dynamically determine the library architecture string (e.g., x86_64-linux-gnu)
if command -v dpkg-architecture &>/dev/null; then
    LIB_ARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
else
    LIB_ARCH="$(uname -m)-linux-gnu"
fi

# Colour helpers - fall back gracefully if not a terminal
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${CYAN}[mesa-fp16]${RESET} $*"; }
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
        --help|-h)
            sed -n '2,23p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown argument: $arg  (try --help)" ;;
    esac
done

# -- Sanity checks -------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must be run as root (use sudo)."
    fi
}

verify_fp16() {
    hr
    log "Verifying cl_khr_fp16 availability..."
    if ! command -v clinfo &>/dev/null; then
        warn "clinfo not found - install ocl-icd-opencl-dev or clinfo package."
        return 0
    fi

    local output
    output=$(RUSTICL_ENABLE=radeonsi clinfo 2>/dev/null || true)
    echo "$output" | grep -E "Device Name|Driver Version|cl_khr_fp16|Half-precision" || true

    if echo "$output" | grep -q "cl_khr_fp16"; then
        ok "cl_khr_fp16 is present - Mesa rusticl fp16 is working!"
    else
        warn "cl_khr_fp16 not found in clinfo output."
        warn "Ensure you have the right driver environment and DRI_PRIME variables set."
    fi
    return 0
}

verify_vulkan() {
    hr
    log "Verifying Vulkan (RADV) availability..."

    local vk_icd="${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.x86_64.json"
    if [ ! -f "${vk_icd}" ]; then
        warn "RADV ICD JSON not found at ${vk_icd} - Vulkan may not have been built."
        return 0
    fi
    ok "RADV ICD JSON present: ${vk_icd}"

    if command -v vulkaninfo &>/dev/null; then
        local vk_out
        vk_out=$(VK_ICD_FILENAMES="${vk_icd}" vulkaninfo --summary 2>/dev/null || true)
        echo "$vk_out" | grep -E "GPU|driverName|driverInfo|apiVersion" || true
        if echo "$vk_out" | grep -qi "radv\|radeon"; then
            ok "RADV Vulkan device detected - Mesa Vulkan is working!"
        else
            warn "RADV device not confirmed in vulkaninfo output. Check DRI_PRIME / render node."
        fi
    else
        warn "vulkaninfo not installed (apt install vulkan-tools). Skipping live check."
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

pkg_exists() {
    apt-cache show "$1" &>/dev/null 2>&1
}

install_deps() {
    hr
    log "Phase 1/5 - Installing build dependencies..."

    apt-get update -qq

    local VER
    VER=$(detect_llvm_version)
    log "Detected LLVM version: ${VER}"

    # -- Core build tools ------------------------------------------------------
    apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils git cmake \
        meson ninja-build pkg-config \
        python3 python3-mako python3-yaml \
        gcc g++ bison flex libelf-dev

    # -- LLVM / Clang ----------------------------------------------------------
    apt-get install -y --no-install-recommends \
        "llvm-${VER}-dev" \
        "libclang-${VER}-dev" \
        "clang-${VER}"

    if pkg_exists "libclang-cpp${VER}-dev"; then
        apt-get install -y --no-install-recommends "libclang-cpp${VER}-dev"
    elif pkg_exists "libclang-cpp-${VER}-dev"; then
        apt-get install -y --no-install-recommends "libclang-cpp-${VER}-dev"
    fi

    # -- SPIRV-LLVM-Translator -------------------------------------------------
    if pkg_exists "llvm-spirv-${VER}"; then
        apt-get install -y --no-install-recommends "llvm-spirv-${VER}"
        if [ ! -f /usr/bin/llvm-spirv ] && [ -f "/usr/bin/llvm-spirv-${VER}" ]; then
            ln -sf "/usr/bin/llvm-spirv-${VER}" /usr/bin/llvm-spirv
        fi
    fi

    if pkg_exists "libllvmspirvlib-${VER}-dev"; then
        apt-get install -y --no-install-recommends "libllvmspirvlib-${VER}-dev"
    elif pkg_exists "libllvmspirvlib-dev"; then
        apt-get install -y --no-install-recommends "libllvmspirvlib-dev"
    fi

    # -- libclc (kept to satisfy package trees, overridden by build_libclc) ---
    if pkg_exists "libclc-${VER}-dev"; then
        apt-get install -y --no-install-recommends "libclc-${VER}" "libclc-${VER}-dev"
    elif pkg_exists "libclc-dev"; then
        apt-get install -y --no-install-recommends libclc-dev
    fi

    # -- Rust ------------------------------------------------------------------
    apt-get install -y --no-install-recommends rustc cargo rustfmt

    if pkg_exists "bindgen"; then
        apt-get install -y --no-install-recommends bindgen
    elif pkg_exists "rust-bindgen"; then
        apt-get install -y --no-install-recommends rust-bindgen
    fi

    # -- SPIR-V tools ----------------------------------------------------------
    apt-get install -y --no-install-recommends spirv-tools

    if pkg_exists "spirv-tools-dev"; then
        apt-get install -y --no-install-recommends spirv-tools-dev
    fi

    if pkg_exists "spirv-headers"; then
        apt-get install -y --no-install-recommends spirv-headers
    fi

    if pkg_exists "libspirv-cross-c-shared-dev"; then
        apt-get install -y --no-install-recommends libspirv-cross-c-shared-dev
    fi

    # -- Vulkan dependencies ---------------------------------------------------
    log "Installing Vulkan build dependencies..."
    apt-get install -y --no-install-recommends \
        libvulkan-dev \
        glslang-tools \
        glslang-dev

    # libvulkan loader + layer support
    if pkg_exists "libvulkan1"; then
        apt-get install -y --no-install-recommends libvulkan1
    fi

    # Vulkan utility libraries (replaces vulkan-validationlayers-dev on newer Ubuntu)
    if pkg_exists "vulkan-utility-libraries-dev"; then
        apt-get install -y --no-install-recommends vulkan-utility-libraries-dev
    elif pkg_exists "vulkan-validationlayers-dev"; then
        apt-get install -y --no-install-recommends vulkan-validationlayers-dev
    fi

    # vulkaninfo for post-build verification
    if pkg_exists "vulkan-tools"; then
        apt-get install -y --no-install-recommends vulkan-tools
    fi

    # wayland/xcb stubs needed even with platforms="" so RADV link does not fail
    apt-get install -y --no-install-recommends \
        libwayland-dev \
        libx11-xcb-dev \
        libxcb-dri3-dev \
        libxcb-present-dev \
        libxcb-randr0-dev \
        libxcb-shm0-dev \
        libxshmfence-dev

    # -- DRM + misc ------------------------------------------------------------
    apt-get install -y --no-install-recommends \
        libdrm-dev \
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

# -- Phase 1.5: Build Custom libclc --------------------------------------------
build_libclc() {
    hr
    log "Phase 1.5/5 - Building libclc from source (Fixing Ubuntu's missing FP16 builtins)..."

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

    ninja -j"$(nproc)"
    ninja install
    ok "Custom libclc installed to ${MESA_PREFIX}"
}

# -- Phase 2: Fetch + verify ---------------------------------------------------
fetch_mesa() {
    hr
    log "Phase 2/5 - Fetching Mesa ${MESA_VERSION}..."

    if [ -f "${TARBALL}" ]; then
        log "Tarball already present - verifying checksum..."
        if echo "${MESA_SHA256}  ${TARBALL}" | sha256sum -c - &>/dev/null; then
            ok "Cached tarball verified."
            return 0
        else
            warn "Cached tarball checksum mismatch - re-downloading."
            rm -f "${TARBALL}"
        fi
    fi

    curl -fsSL --progress-bar "${MESA_URL}" -o "${TARBALL}"
    echo "${MESA_SHA256}  ${TARBALL}" | sha256sum -c - \
        || die "SHA256 verification failed - download may be corrupted."
    ok "Mesa ${MESA_VERSION} downloaded and verified."
}

# -- Phase 3: Extract + configure ----------------------------------------------
configure_mesa() {
    hr
    log "Phase 3/5 - Configuring Mesa (rusticl + radeonsi + RADV Vulkan)..."

    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    tar -xJ -C "${BUILD_DIR}" --strip-components=1 -f "${TARBALL}"

    cd "${BUILD_DIR}"

    local meson_opts=(
        --prefix="${MESA_PREFIX}"
        --buildtype=release
        -Db_ndebug=true
        # Gallium: radeonsi for OpenCL/rusticl + software fallbacks
        -Dgallium-drivers=radeonsi,llvmpipe,softpipe
        # Vulkan: RADV (AMD open-source Vulkan driver)
        -Dvulkan-drivers=amd
        # No display platforms needed for compute-only + headless Vulkan
        -Dplatforms=x11,wayland
        -Dglx=disabled
        -Degl=disabled
        -Dgbm=disabled
        -Dgles1=disabled
        -Dgles2=disabled
        -Dopengl=false
        # rusticl OpenCL
        -Dgallium-rusticl=true
        # LLVM (required for both radeonsi and RADV)
        -Dllvm=enabled
        -Dshared-llvm=enabled
        -Drust_std=2021
        # Vulkan extras: enable useful layers/extensions
        -Dvulkan-layers=device-select,overlay
    )

    if [ "$NATIVE_OPT" = "true" ]; then
        meson_opts+=("-Dc_args=-march=native" "-Dcpp_args=-march=native")
        log "Native CPU optimization enabled (-march=native)"
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
    log "Phase 4/5 - Building Mesa (this takes ~10-20 min on nproc=$(nproc))..."

    local gcc_dir
    gcc_dir=$(dirname "$(gcc -print-libgcc-file-name)")
    export BINDGEN_EXTRA_CLANG_ARGS="--gcc-install-dir=${gcc_dir}"

    ninja -C "${BUILD_DIR}/builddir" -j"$(nproc)"
    ok "Build complete."

    log "Installing to ${MESA_PREFIX}..."
    ninja -C "${BUILD_DIR}/builddir" install
    ok "Install complete."

    log "Cleaning build tree..."
    rm -rf "${BUILD_DIR}" "${TARBALL}"
    ok "Build tree removed."
}

# -- Phase 5: Register ICDs (OpenCL + Vulkan) ----------------------------------
register_icd() {
    hr
    log "Phase 5/5 - Registering Mesa 26.1 rusticl OpenCL ICD + RADV Vulkan ICD..."

    # ---- OpenCL --------------------------------------------------------------
    local new_icd="${MESA_PREFIX}/etc/OpenCL/vendors/rusticl.icd"
    local new_so="${MESA_PREFIX}/lib/${LIB_ARCH}/libRusticlOpenCL.so.1"
    local cl_link="${ICD_VENDORS}/mesa-261-rusticl.icd"
    local old_icd="${ICD_VENDORS}/rusticl.icd"
    local old_disabled="${ICD_VENDORS}/rusticl.icd.disabled"

    [ -f "${new_icd}" ] || die "Expected OpenCL ICD file not found: ${new_icd}"
    [ -f "${new_so}"  ] || die "Expected OpenCL shared lib not found: ${new_so}"

    mkdir -p "${ICD_VENDORS}"
    ln -sf "${new_icd}" "${cl_link}"
    ok "Linked OpenCL ICD: ${cl_link} -> ${new_icd}"

    if [ -f "${old_icd}" ] && [ ! -L "${old_icd}" ]; then
        mv "${old_icd}" "${old_disabled}"
        ok "Disabled old ICD: ${old_icd} -> ${old_disabled}"
    elif [ -L "${old_icd}" ]; then
        rm -f "${old_icd}"
        ok "Removed stale symlink: ${old_icd}"
    else
        log "No existing ${old_icd} to disable."
    fi

    # ---- Vulkan --------------------------------------------------------------
    # RADV installs its ICD JSON under ${MESA_PREFIX}/share/vulkan/icd.d/
    # We symlink it into the system Vulkan ICD search path.
    local arch
    arch=$(uname -m)
    local radv_icd_src="${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.${arch}.json"
    local vk_link="${VK_ICD_DIR}/mesa-261-radv.json"

    if [ -f "${radv_icd_src}" ]; then
        mkdir -p "${VK_ICD_DIR}"
        ln -sf "${radv_icd_src}" "${vk_link}"
        ok "Linked Vulkan ICD: ${vk_link} -> ${radv_icd_src}"
    else
        warn "RADV Vulkan ICD JSON not found at ${radv_icd_src}."
        warn "Vulkan ICD not registered. Check that -Dvulkan-drivers=amd built correctly."
    fi

    # ---- Vulkan layers -------------------------------------------------------
    local layer_dir="${MESA_PREFIX}/share/vulkan/explicit_layer.d"
    local sys_layer_dir="/etc/vulkan/explicit_layer.d"
    if [ -d "${layer_dir}" ]; then
        mkdir -p "${sys_layer_dir}"
        for layer_json in "${layer_dir}"/*.json; do
            [ -f "$layer_json" ] || continue
            ln -sf "${layer_json}" "${sys_layer_dir}/$(basename "${layer_json}")"
            ok "Linked Vulkan layer: $(basename "${layer_json}")"
        done
    fi

    # ---- ldconfig ------------------------------------------------------------
    log "Registering ${MESA_PREFIX}/lib/${LIB_ARCH} with ldconfig..."
    echo "${MESA_PREFIX}/lib/${LIB_ARCH}" > /etc/ld.so.conf.d/mesa-rusticl.conf
    ldconfig
    ok "ldconfig updated."

    log "OpenCL ICD content:"
    cat "${new_icd}" | sed 's/^/  /'

    if [ -f "${radv_icd_src}" ]; then
        log "Vulkan ICD content:"
        cat "${radv_icd_src}" | sed 's/^/  /'
    fi
}

# -- Runtime environment hint --------------------------------------------------
print_env_hint() {
    local arch
    arch=$(uname -m)
    hr
    cat <<ENV
${BOLD}Runtime environment required (add to container ENV or ~/.bashrc):${RESET}

  # OpenCL / rusticl
  export RUSTICL_ENABLE=radeonsi
  export DRI_PRIME=0
  export LD_LIBRARY_PATH=${MESA_PREFIX}/lib/${LIB_ARCH}:\${LD_LIBRARY_PATH}

  # Vulkan (RADV) - use the Mesa-built ICD explicitly
  export VK_ICD_FILENAMES=${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.${arch}.json

${BOLD}Verify OpenCL fp16:${RESET}
  RUSTICL_ENABLE=radeonsi clinfo | grep -E "cl_khr_fp16|Half-precision"

${BOLD}Verify Vulkan (RADV):${RESET}
  VK_ICD_FILENAMES=${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.${arch}.json vulkaninfo --summary

${BOLD}Precompile Qrack kernels:${RESET}
  RUSTICL_ENABLE=radeonsi DRI_PRIME=0 /usr/local/bin/qrack_cl_precompile

ENV
}

# -- Main ----------------------------------------------------------------------
main() {
    hr
    echo -e "${BOLD}Mesa ${MESA_VERSION} rusticl fp16 + RADV Vulkan builder${RESET}"
    echo -e "Mode: ${YELLOW}${MODE}${RESET}  |  Prefix: ${MESA_PREFIX}  |  $(date)"
    hr

    check_root

    case "$MODE" in
        verify)
            verify_fp16
            verify_vulkan
            ;;
        icd)
            register_icd
            verify_fp16
            verify_vulkan
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
            print_env_hint
            ok "All done. Mesa ${MESA_VERSION} rusticl+fp16 and RADV Vulkan are installed."
            ;;
    esac
}

main "$@"
