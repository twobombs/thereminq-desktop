#!/usr/bin/env bash
# =============================================================================
# build_mesa_rusticl_fp16.sh   (full-feature edition)
#
# Builds Mesa 26.1.4 from source into /usr/local/mesa with the *complete*
# feature set rather than a compute-only slice:
#
#   * rusticl OpenCL ICD with cl_khr_fp16 for vega20 (Radeon Pro VII)
#   * Vulkan: RADV (amd) + NVK (nouveau) + lavapipe + anv/hasvk/virtio
#   * NVIDIA OSS compute path: nouveau gallium + NVK + rusticl-on-nouveau
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
#   sudo ./build_mesa_rusticl_fp16.sh --skip-nouveau # drop nouveau/NVK entirely
#   sudo ./build_mesa_rusticl_fp16.sh --no-rustup    # never bootstrap a Rust toolchain
#   sudo ./build_mesa_rusticl_fp16.sh --keep-build   # keep /tmp/mesa-build for debugging
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

# Colour helpers. Use $'...' so these hold real ESC bytes: `cat <<HEREDOC` does
# not expand backslash escapes, which is why the hint block printed literal
# \033[1m sequences.
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
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
SKIP_NOUVEAU="false"
NO_RUSTUP="false"
KEEP_BUILD="false"
RUSTICL_LIBDIR=""
JOBS="$(nproc)"

while [ $# -gt 0 ]; do
    case "$1" in
        --verify)      MODE="verify" ;;
        --icd-only)    MODE="icd" ;;
        --native)      NATIVE_OPT="true" ;;
        --minimal)     FEATURES="minimal" ;;
        --all-drivers) ALL_DRIVERS="true" ;;
        --glvnd)       USE_GLVND="true" ;;
        --skip-nouveau) SKIP_NOUVEAU="true" ;;
        --no-rustup)   NO_RUSTUP="true" ;;
        --keep-build)  KEEP_BUILD="true" ;;
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
export RUSTICL_ENABLE=\${RUSTICL_ENABLE:-radeonsi,nouveau}
export DRI_PRIME=\${DRI_PRIME:-0}
export LD_LIBRARY_PATH=${RUSTICL_LIBDIR:+${RUSTICL_LIBDIR}:}${MESA_PREFIX}/lib/${LIB_ARCH}:\${LD_LIBRARY_PATH:-}
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

verify_nouveau() {
    hr
    log "Verifying nouveau / NVK (NVIDIA OSS compute) readiness..."

    # ---- built artefacts -----------------------------------------------------
    local libdir="${MESA_PREFIX}/lib/${LIB_ARCH}"
    local nvk_icd="${MESA_PREFIX}/share/vulkan/icd.d/nouveau_icd.${ARCH}.json"
    if [ -f "${nvk_icd}" ]; then
        ok "NVK ICD built: ${nvk_icd}"
    else
        warn "No NVK ICD at ${nvk_icd} - nouveau was not in vulkan-drivers."
    fi
    if ls "${libdir}"/dri/nouveau_dri.so "${libdir}"/dri/libgallium*.so &>/dev/null; then
        ok "Gallium DRI modules present in ${libdir}/dri"
    fi

    # ---- kernel side ---------------------------------------------------------
    local build_time="false"
    [ -e /dev/dri ] || build_time="true"

    if grep -qw nouveau /proc/modules 2>/dev/null; then
        ok "nouveau kernel module is loaded on the host."
    elif [ -d /sys/module/nouveau ]; then
        ok "nouveau is built into the running kernel."
    else
        warn "nouveau kernel module NOT loaded."
        warn "NVK and rusticl-on-nouveau need the OSS kernel driver; the proprietary"
        warn "nvidia module claims the device exclusively. On the host:"
        warn "  modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia; modprobe nouveau"
    fi

    if grep -qw "nvidia" /proc/modules 2>/dev/null; then
        warn "Proprietary 'nvidia' module is loaded - it will block nouveau from binding."
    fi

    # ---- GSP firmware (Turing and newer require it) --------------------------
    if compgen -G "/lib/firmware/nvidia/*/gsp/*" >/dev/null 2>&1; then
        ok "GSP firmware present under /lib/firmware/nvidia."
    else
        warn "No GSP firmware found under /lib/firmware/nvidia."
        warn "Turing (TU1xx) and newer need it for nouveau to bring the GPU up:"
        warn "  apt install linux-firmware   (host side, not just the container)"
    fi

    # ---- device nodes --------------------------------------------------------
    local nodes
    nodes=$(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ' || true)
    if [ -n "$nodes" ]; then
        ok "Render nodes visible: ${nodes}"
    else
        build_time="true"
        log "No /dev/dri/renderD* here."
        log "During 'docker build' this is normal - the builder has no GPU access,"
        log "so nothing can be enumerated yet. The artefact checks above are what"
        log "matter at this stage."
    fi

    if command -v lspci &>/dev/null; then
        lspci -nnk 2>/dev/null | grep -A3 -i "VGA\|3D controller" | grep -i "nvidia\|nouveau" || true
    fi

    # ---- live probes ---------------------------------------------------------
    if command -v vulkaninfo &>/dev/null && [ -f "${nvk_icd}" ]; then
        local nvk_out
        nvk_out=$( eval "$(mesa_env_exports)"; VK_ICD_FILENAMES="${nvk_icd}" vulkaninfo --summary 2>/dev/null || true )
        if echo "$nvk_out" | grep -qi "NVK\|nouveau"; then
            ok "NVK reports a device:"
            echo "$nvk_out" | grep -E "deviceName|driverName|driverInfo|apiVersion" || true
        elif [ "$build_time" = "true" ]; then
            log "NVK built; device enumeration deferred to runtime."
        else
            warn "NVK built but no device enumerated - check the kernel module and firmware above."
        fi
    fi

    if command -v clinfo &>/dev/null; then
        local nv_cl
        nv_cl=$( eval "$(mesa_env_exports)"; RUSTICL_ENABLE=nouveau clinfo 2>/dev/null || true )
        if echo "$nv_cl" | grep -qi "NV\|nouveau"; then
            ok "rusticl exposes an OpenCL device on nouveau:"
            echo "$nv_cl" | grep -E "Device Name|Device Version|Max compute units|cl_khr_fp16|cl_khr_fp64" || true
        elif [ "$build_time" = "true" ]; then
            log "rusticl-on-nouveau built; device enumeration deferred to runtime."
        else
            warn "rusticl found no nouveau OpenCL device (RUSTICL_ENABLE=nouveau)."
            warn "Check the kernel module, GSP firmware and /dev/dri passthrough above."
        fi
    fi

    if [ "$build_time" = "true" ]; then
        hr
        log "To verify the NVIDIA path once the container is actually running:"
        log "  docker run --rm --device /dev/dri --group-add video --group-add render \\"
        log "    <image> /root/$(basename "$0") --verify"
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

# -- Rust toolchain + cbindgen (required by src/nouveau/nil => nouveau + NVK) --
CBINDGEN_MIN="0.25.0"
CBINDGEN_FALLBACKS="0.29.0 0.28.0 0.27.0 0.26.0"
RUSTUP_PREFIX="/opt/rust"
RUSTC_FALLBACK_MIN="1.78.0"

rustc_version() {
    rustc --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

version_ge() {  # version_ge HAVE WANT
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# Mesa's Rust floor rises fast and NVK's nil crate is usually the first thing to
# hit it. Read the requirement out of the tree when we can, else assume a floor.
mesa_rust_requirement() {
    local want=""
    if [ -f "${BUILD_DIR}/meson.build" ]; then
        want=$(grep -hoP "rust[^\n]*version_compare\(\s*'>=\s*\K[0-9]+\.[0-9]+(\.[0-9]+)?" \
                 "${BUILD_DIR}/meson.build" 2>/dev/null | sort -V | tail -1 || true)
        [ -n "$want" ] || want=$(grep -hoP "rust_req\w*\s*=\s*'>=?\s*\K[0-9]+\.[0-9]+(\.[0-9]+)?" \
                 "${BUILD_DIR}/meson.build" 2>/dev/null | sort -V | tail -1 || true)
    fi
    echo "${want:-$RUSTC_FALLBACK_MIN}"
}

bootstrap_rustup() {
    if [ "$NO_RUSTUP" = "true" ]; then
        warn "--no-rustup set; not bootstrapping a newer Rust toolchain."
        return 1
    fi
    log "Bootstrapping an up-to-date Rust toolchain into ${RUSTUP_PREFIX}..."
    export RUSTUP_HOME="${RUSTUP_PREFIX}" CARGO_HOME="${RUSTUP_PREFIX}"
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
         | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path >/dev/null 2>&1; then
        warn "rustup bootstrap failed (no network to sh.rustup.rs?)."
        return 1
    fi
    export PATH="${RUSTUP_PREFIX}/bin:${PATH}"
    hash -r
    # Persist for later phases and for meson's compiler probing.
    printf 'export RUSTUP_HOME=%s\nexport CARGO_HOME=%s\nexport PATH=%s/bin:$PATH\n' \
        "${RUSTUP_PREFIX}" "${RUSTUP_PREFIX}" "${RUSTUP_PREFIX}" > /etc/profile.d/rustup-mesa.sh
    ok "Rust toolchain: $(rustc_version) (rustup, ${RUSTUP_PREFIX})"
    return 0
}

ensure_rust_toolchain() {
    local want have
    want=$(mesa_rust_requirement)
    have=$(rustc_version)

    if [ -z "$have" ]; then
        warn "No rustc on PATH."
        bootstrap_rustup || die "Rust is required for rusticl and NVK. Install rustc >= ${want}."
        return 0
    fi

    if version_ge "$have" "$want"; then
        ok "rustc ${have} satisfies Mesa's requirement (>= ${want})."
        return 0
    fi

    warn "rustc ${have} is older than Mesa's requirement (>= ${want})."
    if bootstrap_rustup; then
        have=$(rustc_version)
        version_ge "$have" "$want" \
            || die "rustup toolchain ${have} still below ${want}."
        return 0
    fi
    die "rustc ${have} < ${want}. Install a newer toolchain (rustup) and re-run."
}

cbindgen_ok() {
    command -v cbindgen &>/dev/null || return 1
    local v
    v=$(cbindgen --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$v" ] || return 1
    version_ge "$v" "$CBINDGEN_MIN"
}

cargo_install_cbindgen() {  # cargo_install_cbindgen [version]
    local ver="${1:-}" args=(install --locked cbindgen --root /usr/local)
    [ -n "$ver" ] && args+=(--version "$ver")
    CARGO_HOME="${CARGO_HOME:-/tmp/cargo-cbindgen}" cargo "${args[@]}" >/dev/null 2>&1
}

ensure_cbindgen() {
    if cbindgen_ok; then
        ok "cbindgen present: $(cbindgen --version 2>/dev/null | head -1)"
        return 0
    fi

    log "cbindgen missing or too old - trying distro packages..."
    apt_first rust-cbindgen cbindgen
    hash -r
    if cbindgen_ok; then
        ok "cbindgen from apt: $(cbindgen --version 2>/dev/null | head -1)"
        return 0
    fi

    command -v cargo &>/dev/null || return 1

    log "Building cbindgen from crates.io (a few minutes)..."
    if cargo_install_cbindgen; then
        hash -r
        cbindgen_ok && { ok "cbindgen: $(cbindgen --version | head -1)"; return 0; }
    fi

    # Newest cbindgen may need a newer rustc than the host has; walk back.
    local v
    for v in $CBINDGEN_FALLBACKS; do
        log "Retrying with pinned cbindgen ${v}..."
        if cargo_install_cbindgen "$v"; then
            hash -r
            cbindgen_ok && { ok "cbindgen ${v} installed."; return 0; }
        fi
    done

    rm -rf /tmp/cargo-cbindgen
    return 1
}

# Nouveau/NVK need both a modern rustc and cbindgen. Called when nouveau is in
# the driver set, and fatal there - silently dropping the driver would defeat
# the point of the build.
ensure_nouveau_toolchain() {
    hr
    log "Preparing nouveau/NVK build tooling..."
    ensure_rust_toolchain
    if ensure_cbindgen; then
        ok "nouveau/NVK prerequisites satisfied."
        return 0
    fi
    die "cbindgen >= ${CBINDGEN_MIN} could not be installed, and nouveau/NVK need it.
       Fix the network path to crates.io, install rust-cbindgen manually, or
       re-run with --skip-nouveau to build without nouveau and NVK."
}

# drop_value <comma-list> <value>  -> list with that value removed
drop_value() {
    local list="$1" drop="$2" out=() v
    local IFS=','
    read -ra arr <<<"$list"
    unset IFS
    for v in "${arr[@]}"; do
        [ "$v" = "$drop" ] || out+=("$v")
    done
    ( IFS=','; echo "${out[*]}" )
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
    # Mesa's nouveau NIL layer generates C headers with cbindgen at configure
    # time; without it `meson setup` aborts outright. Do it early so a missing
    # toolchain surfaces in ~1 min rather than 9 min into the build.
    if [ "$SKIP_NOUVEAU" = "true" ]; then
        log "--skip-nouveau: not installing cbindgen."
    else
        ensure_rust_toolchain
        ensure_cbindgen || warn "cbindgen not yet available; will retry at configure time."
    fi

    # -- SPIR-V tools ----------------------------------------------------------
    apt_require spirv-tools
    apt_optional spirv-tools-dev spirv-headers libspirv-cross-c-shared-dev

    # -- Vulkan ----------------------------------------------------------------
    log "Installing Vulkan build dependencies..."
    apt_require libvulkan-dev glslang-tools
    apt_optional glslang-dev libvulkan1 vulkan-tools
    # VkLayer_MESA_screenshot links libpng; without it meson aborts.
    apt_optional libpng-dev libjpeg-dev
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
                     mesa-utils pciutils
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

    if [ "$llvm_ver" != "?" ] && [ "$spirv_ver" != "?" ]; then
        if [ "$llvm_ver" != "$spirv_ver" ]; then
            die "LLVM major (${llvm_ver}) != llvm-spirv major (${spirv_ver}). Install matching llvm-spirv-${llvm_ver} and retry."
        fi
        ok "LLVM ${llvm_ver} and llvm-spirv ${spirv_ver} major versions match."
    else
        warn "llvm-spirv CLI not found - cannot compare CLI versions."
    fi

    # rusticl links LLVMSPIRVLib; the CLI is incidental. Check the library,
    # because its absence is a common reason for rusticl to be turned off.
    if pkg-config --exists LLVMSPIRVLib 2>/dev/null; then
        ok "LLVMSPIRVLib found via pkg-config ($(pkg-config --modversion LLVMSPIRVLib 2>/dev/null))."
    elif ls /usr/lib/*/libLLVMSPIRVLib.so* &>/dev/null || ls /usr/lib/libLLVMSPIRVLib.so* &>/dev/null; then
        ok "libLLVMSPIRVLib present on the system."
    else
        warn "libLLVMSPIRVLib not found. rusticl needs the SPIRV-LLVM-Translator"
        warn "library; without it meson may configure rusticl off. Install"
        warn "libllvmspirvlib-${llvm_ver}-dev (or libllvmspirvlib-dev) if the"
        warn "configure check below reports gallium-rusticl as disabled."
    fi
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
MESA_OPT_NAMES=""

# Parse every option name once. This MUST be multiline-aware: Mesa writes
#   option(
#     'gallium-drivers',
# so a line-based grep for "option(\s*'name'" matches nothing and every single
# option silently looks unsupported.
load_opt_names() {
    [ -n "${MESA_OPT_FILE}" ] || return 0
    MESA_OPT_NAMES=$(python3 - "${MESA_OPT_FILE}" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
for m in re.finditer(r"option\(\s*'([^']+)'", src):
    print(m.group(1))
PYEOF
)
    local n
    n=$(grep -c . <<<"${MESA_OPT_NAMES}" || echo 0)
    log "Parsed ${n} meson options from $(basename "${MESA_OPT_FILE}")."

    # Sanity gate: if the parser cannot see options that have existed for a
    # decade, it is broken - and a broken parser silently drops every -D flag.
    local probe missing=()
    for probe in gallium-drivers platforms llvm; do
        grep -qx -- "$probe" <<<"${MESA_OPT_NAMES}" || missing+=("$probe")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Option parsing failed - core options not found: ${missing[*]}
       ${MESA_OPT_FILE} may use a format this script cannot read.
       Refusing to continue: every -D flag would be dropped silently."
    fi
    ok "Option parser sanity check passed."
}

locate_opt_file() {
    local f
    for f in "${BUILD_DIR}/meson.options" "${BUILD_DIR}/meson_options.txt"; do
        [ -f "$f" ] && { MESA_OPT_FILE="$f"; load_opt_names; return 0; }
    done
    die "No meson.options / meson_options.txt in ${BUILD_DIR}.
       Without it every build option would be dropped silently."
}

opt_exists() {
    [ -n "${MESA_OPT_NAMES}" ] || return 0
    grep -qx -- "$1" <<<"${MESA_OPT_NAMES}"
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

# add_opt_required <value> <name> [alt-names...]
# Tries each option name in turn; dies if none exist. Use for anything whose
# silent absence would produce a build that looks fine but is missing the
# feature we came for (rusticl, LLVM, drivers).
add_opt_required() {
    local value="$1"; shift
    local name
    for name in "$@"; do
        if opt_exists "$name"; then
            meson_opts+=("-D${name}=${value}")
            [ "$name" = "$1" ] || log "using alternate option name: ${name}"
            return 0
        fi
    done
    die "Mesa ${MESA_VERSION} offers none of these required options: $*
       The build would silently omit the feature. Check ${MESA_OPT_FILE}."
}

# Read an option's value back out of the configured build directory.
build_opt_value() {
    meson introspect --buildoptions "${BUILD_DIR}/builddir" 2>/dev/null \
      | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in d:
    if o.get('name') == sys.argv[1]:
        print(o.get('value'))
        break
" "$1"
}

# Confirm after configure that the features we asked for are really on, before
# spending 30 minutes compiling something unusable.
assert_configured() {
    local rusticl
    rusticl=$(build_opt_value gallium-rusticl)
    case "$rusticl" in
        True|true|1) ok "configure check: gallium-rusticl is enabled." ;;
        "")          warn "configure check: could not read gallium-rusticl back from meson." ;;
        *)           die "configure check: gallium-rusticl resolved to '${rusticl}'.
       rusticl would not be built - aborting before the long compile." ;;
    esac

    local drivers
    drivers=$(build_opt_value gallium-drivers)
    [ -z "$drivers" ] || log "configure check: gallium-drivers = ${drivers}"
    drivers=$(build_opt_value vulkan-drivers)
    [ -z "$drivers" ] || log "configure check: vulkan-drivers  = ${drivers}"
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

    # nouveau gallium and NVK both build src/nouveau/nil, which needs cbindgen
    # and a current rustc. This is a wanted target (NVIDIA OSS compute), so a
    # missing toolchain is a hard error, not a silent driver drop.
    if [ "$SKIP_NOUVEAU" = "true" ]; then
        log "--skip-nouveau: excluding nouveau gallium and NVK."
        gallium=$(drop_value "$gallium" nouveau)
        vulkan=$(drop_value "$vulkan" nouveau)
    elif grep -q "nouveau" <<<"${gallium},${vulkan}"; then
        ensure_nouveau_toolchain
    fi

    platforms=$(filter_values platforms "$PLATFORMS_WANT")
    layers=$(filter_values vulkan-layers "$VK_LAYERS_WANT")

    # Some layers pull in external libraries that are not needed by any driver.
    # A missing one aborts configure outright, so drop the layer instead - none
    # of them matter for compute.
    if grep -q "screenshot" <<<"${layers}" && ! pkg-config --exists libpng 2>/dev/null; then
        warn "libpng not found - dropping the Vulkan screenshot layer."
        warn "Install libpng-dev and re-run if you want it."
        layers=$(drop_value "$layers" screenshot)
    fi

    [ -n "$gallium" ] || die "No usable gallium drivers left after filtering."
    log "gallium-drivers : ${gallium}"
    log "vulkan-drivers  : ${vulkan:-<none>}"
    log "platforms       : ${platforms:-<none>}"

    add_opt_required "${gallium}" gallium-drivers
    [ -n "$vulkan" ]   && add_opt "-Dvulkan-drivers=${vulkan}"
    [ -n "$platforms" ] && add_opt "-Dplatforms=${platforms}"
    [ -n "$layers" ]   && add_opt "-Dvulkan-layers=${layers}"

    # ---- rusticl / OpenCL (the point of the exercise) ------------------------
    add_opt_required "true" gallium-rusticl rusticl gallium-opencl-rusticl
    add_opt "-Dopencl-spirv=true"
    add_opt_required "enabled" llvm
    add_opt "-Dshared-llvm=enabled"
    add_opt "-Drust_std=2021"

    # Newer Mesa gates which gallium drivers rusticl exposes. Enable every
    # compute-capable one we actually built, so RUSTICL_ENABLE can pick between
    # radeonsi (Radeon Pro VII) and nouveau (NVIDIA OSS compute) at runtime.
    if opt_exists "rusticl-enable-drivers"; then
        local rusticl_want rusticl_drv
        rusticl_want="$gallium,llvmpipe,swrast"
        rusticl_drv=$(filter_values rusticl-enable-drivers "$rusticl_want")
        if [ -n "$rusticl_drv" ]; then
            add_opt "-Drusticl-enable-drivers=${rusticl_drv}"
            log "rusticl drivers  : ${rusticl_drv}"
        fi
    fi

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
    assert_configured
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

    # Keep the evidence: once the build tree is gone there is no way to tell
    # which options meson actually resolved.
    local info="${MESA_PREFIX}/share/mesa-build-info"
    mkdir -p "${info}"
    meson configure "${BUILD_DIR}/builddir" > "${info}/buildoptions.txt" 2>/dev/null || true
    meson introspect --buildoptions "${BUILD_DIR}/builddir" > "${info}/buildoptions.json" 2>/dev/null || true
    cp -f "${BUILD_DIR}/builddir/meson-logs/meson-log.txt" "${info}/" 2>/dev/null || true
    date -u +"built %Y-%m-%dT%H:%M:%SZ mesa ${MESA_VERSION}" > "${info}/stamp.txt"
    ok "Build metadata saved to ${info}"

    if [ "$KEEP_BUILD" = "true" ]; then
        log "--keep-build: leaving ${BUILD_DIR} in place."
    else
        log "Cleaning build tree..."
        rm -rf "${BUILD_DIR}" "${TARBALL}"
        ok "Build tree removed."
    fi
}

# -- Phase 5: Register ICDs (OpenCL + Vulkan) ----------------------------------
find_rusticl_lib() {
    local f
    # Preferred location first, then anywhere under the prefix: Mesa has moved
    # this between ${prefix}/lib and ${prefix}/lib/<triplet> across releases.
    for f in "${MESA_PREFIX}/lib/${LIB_ARCH}/libRusticlOpenCL.so.1" \
             "${MESA_PREFIX}/lib/libRusticlOpenCL.so.1"; do
        [ -e "$f" ] && { echo "$f"; return 0; }
    done
    f=$(find "${MESA_PREFIX}" -maxdepth 5 -name 'libRusticlOpenCL.so.1' -print -quit 2>/dev/null)
    [ -n "$f" ] || f=$(find "${MESA_PREFIX}" -maxdepth 5 -name 'libRusticlOpenCL.so*' -print -quit 2>/dev/null)
    [ -n "$f" ] || return 1
    echo "$f"
}

diagnose_missing_rusticl() {
    hr
    warn "libRusticlOpenCL was not installed. What IS in the prefix:"
    find "${MESA_PREFIX}" -maxdepth 4 -name '*.so*' -printf '  %p\n' 2>/dev/null | head -30
    echo
    if [ -f "${MESA_PREFIX}/share/mesa-build-info/buildoptions.txt" ]; then
        warn "Configured rusticl-related options were:"
        grep -i "rusticl\|opencl\|llvm" "${MESA_PREFIX}/share/mesa-build-info/buildoptions.txt" \
            | sed 's/^/  /' | head -20
    fi
    echo
    die "rusticl was configured but produced no library.
       Most likely causes:
         * gallium-rusticl was accepted but disabled by a missing dependency
           (LLVM SPIR-V translator, libclc, or a rust/bindgen version mismatch)
         * no rusticl-capable driver in gallium-drivers
       Re-run the build; configure now aborts early if rusticl is off, and
       ${MESA_PREFIX}/share/mesa-build-info/ holds the meson logs."
}

register_opencl_icd() {
    local new_so
    if ! new_so=$(find_rusticl_lib); then
        diagnose_missing_rusticl
    fi
    ok "Found rusticl library: ${new_so}"

    local lib_parent
    lib_parent=$(dirname "${new_so}")
    if [ "${lib_parent}" != "${MESA_PREFIX}/lib/${LIB_ARCH}" ]; then
        warn "rusticl installed to ${lib_parent}, not ${MESA_PREFIX}/lib/${LIB_ARCH}."
        warn "Runtime env below uses the actual path."
        RUSTICL_LIBDIR="${lib_parent}"
    fi

    local cl_icd="${ICD_VENDORS}/mesa-${MESA_VERSION%%.*}-rusticl.icd"
    local old_icd="${ICD_VENDORS}/rusticl.icd"
    local old_disabled="${ICD_VENDORS}/rusticl.icd.disabled"

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
    local icd_dir="${MESA_PREFIX}/share/vulkan/icd.d" icd_list=""
    if [ -d "${icd_dir}" ] && compgen -G "${icd_dir}/*.json" >/dev/null; then
        icd_list=$(printf '%s:' "${icd_dir}"/*.json); icd_list="${icd_list%:}"
    fi
    cat <<ENV
${BOLD}Scoped usage (recommended - no impact on the system GL stack):${RESET}

  mesa-env clinfo | grep -E "cl_khr_fp16|Half-precision"
  mesa-env vulkaninfo --summary
  mesa-env glxinfo -B
  mesa-env vainfo
  mesa-env /usr/local/bin/qrack_cl_precompile

${BOLD}Or export manually (container ENV / ~/.bashrc):${RESET}

$(mesa_env_exports | sed 's/^/  /')
  export VK_ICD_FILENAMES=${icd_list:-${MESA_PREFIX}/share/vulkan/icd.d/radeon_icd.${ARCH}.json}

${BOLD}NVIDIA OSS compute (nouveau + NVK):${RESET}

  # OpenCL on NVIDIA via rusticl
  RUSTICL_ENABLE=nouveau mesa-env clinfo
  # Both GPUs enumerated in one context
  RUSTICL_ENABLE=radeonsi,nouveau mesa-env clinfo -l
  # Vulkan compute via NVK
  VK_ICD_FILENAMES=${MESA_PREFIX}/share/vulkan/icd.d/nouveau_icd.${ARCH}.json mesa-env vulkaninfo --summary
  # GL on NVK through zink
  MESA_LOADER_DRIVER_OVERRIDE=zink mesa-env glxinfo -B

  Host/container requirements for this path:
    * nouveau kernel module loaded, proprietary 'nvidia' module NOT loaded
    * GSP firmware present (linux-firmware) for Turing and newer
    * container started with --device /dev/dri (plus video/render group access)
  Note the Dockerfile's ENV RUSTICL_ENABLE=radeonsi overrides the default here;
  set it to radeonsi,nouveau to expose both devices to Qrack.

${BOLD}Rebuild variants:${RESET}
  --minimal      compute-only (rusticl + radeonsi + RADV, no GL)
  --all-drivers  every gallium/vulkan driver this Mesa offers
  --glvnd        build as a libglvnd vendor instead of standalone libGL
  --skip-nouveau drop nouveau gallium + NVK (avoids the cbindgen dependency)
  --no-rustup    fail instead of bootstrapping rustup when rustc is too old
  --keep-build   keep the build tree and meson logs after install
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
            [ "$SKIP_NOUVEAU" = "true" ] || verify_nouveau
            ;;
        icd)
            register_icd
            verify_fp16
            verify_vulkan
            [ "$FEATURES" = "all" ] && verify_gl
            [ "$SKIP_NOUVEAU" = "true" ] || verify_nouveau
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
            [ "$SKIP_NOUVEAU" = "true" ] || verify_nouveau
            print_env_hint
            ok "All done. Mesa ${MESA_VERSION} installed with the full feature set."
            ;;
    esac
}

main "$@"
