#!/usr/bin/env bash
set -euo pipefail

# build.sh — Kernel builder for Poco X3 NFC (surya)
# Kernel: 4.14 | Author: Fannndi | Toolchain: GCC 17 + LLD 23

# ── Timezone ──────────────────────────────────────────────────────────────────
export TZ="Asia/Jakarta"   # WIB UTC+7 — berlaku untuk semua date call

# ── Configuration ─────────────────────────────────────────────────────────────

KERNEL_NAME="${KERNEL_NAME:-Farewell-EXT}"
DEFCONFIG="${DEFCONFIG:-surya_defconfig}"
OUTDIR="${OUTDIR:-out}"
ARCH="arm64"
SUBARCH="arm64"
BUILD_USER="${BUILD_USER:-Fannndi}"
BUILD_HOST="${BUILD_HOST:-WSL}"
MAKE_PROCS="${MAKE_PROCS:-$(nproc)}"
BUILD_START=$(date +%s)

OFFLINE="${OFFLINE:-0}"
WARN_DETAIL="${WARN_DETAIL:-1}"

EVA_GCC_REPO="${EVA_GCC_REPO:-mvaisakh/gcc-build}"
EVA_GCC_TAG="${EVA_GCC_TAG:-}"
EVA_GCC_ARM64_DIR="${EVA_GCC_ARM64_DIR:-}"
EVA_GCC_ARM_DIR="${EVA_GCC_ARM_DIR:-}"

ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/fannndi/Kernel_Zip}"
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-Farewell}"
MKDTBOIMG_URL="https://android.googlesource.com/platform/system/libufdt/+/refs/heads/main/utils/src/mkdtboimg.py?format=TEXT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/toolchains}"
MKDTBOIMG_SCRIPT="${CACHE_DIR}/mkdtboimg.py"
ANYKERNEL_DIR="${CACHE_DIR}/AnyKernel3"
ARTIFACT_DIR="build-artifacts"
LOGFILE="${ARTIFACT_DIR}/log.txt"
WARN_FILE="${ARTIFACT_DIR}/warnings.txt"
ZIPNAME="${KERNEL_NAME// /_}-GCC-$(date '+%d%m%Y-%H%M').zip"   # WIB ✓

_KCFLAGS_CACHE=""
_LLDFLAGS_CACHE=""

if ! command -v python &>/dev/null && command -v python3 &>/dev/null; then
    mkdir -p "$CACHE_DIR/bin"
    ln -sf "$(which python3)" "$CACHE_DIR/bin/python"
    export PATH="$CACHE_DIR/bin:$PATH"
fi

# ── Logging ───────────────────────────────────────────────────────────────────

CSI="\e["; CLR_RST="${CSI}0m"
_log() { local c="$1"; shift; echo -e "${c}$*${CLR_RST}" >&2; }
info()  { _log "${CSI}1;34m" "[i] $*"; }
ok()    { _log "${CSI}1;32m" "[OK] $*"; }
warn()  { _log "${CSI}1;33m" "[W] $*"; }
err()   { _log "${CSI}1;31m" "[ERR] $*"; }
debug() { _log "${CSI}1;36m" "[DBG] $*"; }
_elapsed() { local s=$(( $(date +%s) - $1 )); echo "$(( s/60 ))m $(( s%60 ))s"; }

# ── Setup ─────────────────────────────────────────────────────────────────────

[[ -d "$ARTIFACT_DIR" ]] && rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"
exec > >(tee -i "$LOGFILE") 2>&1

_on_exit() {
    local code=$?
    [[ $code -ne 0 ]] && err "Build failed. Check ${LOGFILE} for details."
    exit $code
}
trap '_on_exit' ERR SIGINT SIGTERM

info "Kernel Builder — Poco X3 NFC (surya) | Kernel 4.14 | GCC 17 + LLD 23"
info "SM7150-AC (732G): 2x Kryo 470 Gold (A76) @ 2.3GHz + 6x Kryo 470 Silver (A55) @ 1.8GHz"
info "Mode: ALWAYS CLEAN | offline=${OFFLINE} | warn_detail=${WARN_DETAIL} | Jobs=${MAKE_PROCS} | TZ=WIB"

# ── Early Validation ──────────────────────────────────────────────────────────

_validate_early() {
    [[ -f "Makefile" ]] || { err "Makefile not found — run from kernel root."; exit 1; }
    local src="arch/${ARCH}/configs/${DEFCONFIG}"
    [[ -f "$src" ]] || { err "Defconfig not found: $src"; exit 1; }
    ok "Source OK — $src"
}

# ── Stale Temp Cleanup ────────────────────────────────────────────────────────

_cleanup_stale_temps() {
    while IFS= read -r -d '' f; do
        warn "Removing stale temp: $(basename "$f")"
        rm -rf "$f"
    done < <(find "$CACHE_DIR" -maxdepth 1 \
        \( -name "*.extracting" -o -name "*.xz.tmp" \) -print0 2>/dev/null)
}

# ── EVA GCC Fetch ─────────────────────────────────────────────────────────────

_get_latest_tag() {
    local url="https://api.github.com/repos/${EVA_GCC_REPO}/releases/latest"
    local raw=""
    command -v curl >/dev/null 2>&1 && raw=$(curl -fsSL --max-time 20 "$url" 2>/dev/null)
    command -v wget >/dev/null 2>&1 && [[ -z "$raw" ]] \
        && raw=$(wget -qO- --timeout=20 "$url" 2>/dev/null)
    echo "$raw" | grep -q 'rate limit' && { warn "GitHub rate limited — using cache"; echo ""; return 0; }
    local tag=""
    command -v jq >/dev/null 2>&1 \
        && tag=$(echo "$raw" | jq -r '.tag_name // empty' 2>/dev/null) \
        || tag=$(echo "$raw" | grep '"tag_name"' | head -1 \
            | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    echo "$tag" | tr -d '\r\n' | xargs
}

_find_eva() {
    local prefix="$1" bin="$2" dir hit
    dir=$(find "$CACHE_DIR" -maxdepth 1 -type d -name "${prefix}-*" 2>/dev/null | sort -r | head -1)
    [[ -z "$dir" ]] && return 1
    [[ -f "$dir/bin/$bin" ]] && { echo "$dir"; return 0; }
    hit=$(find "$dir" -maxdepth 4 -type f -name "$bin" 2>/dev/null | head -1)
    [[ -n "$hit" ]] && { echo "${hit%/bin/*}"; return 0; }
    return 1
}

_download() {
    local url="$1" out="$2"
    for i in {1..3}; do
        command -v wget >/dev/null 2>&1 \
            && wget -q --show-progress -O "$out" "$url" && return 0
        command -v curl >/dev/null 2>&1 \
            && curl -L -o "$out" --fail --progress-bar --retry 3 "$url" && return 0
        sleep 3
    done
    return 1
}

_extract() {
    local arc="$1" out_dir="$2" bin="$3"
    [[ -d "$out_dir" ]] && find "$out_dir" -type f -name "$bin" 2>/dev/null | grep -q . && return 0
    rm -rf "$out_dir" && mkdir -p "$out_dir"
    if ! tar -xf "$arc" -C "$out_dir" 2>/dev/null; then
        xz -dk "$arc" -c > "${arc%.xz}.tar" 2>/dev/null \
            && tar -xf "${arc%.xz}.tar" -C "$out_dir" \
            && rm -f "${arc%.xz}.tar"
    fi
    find "$out_dir" -type f -name "$bin" | grep -q . || return 1
}

_fetch_toolchain_arch() {
    local arch="$1" target_tag="$2"
    local prefix="eva-gcc-${arch}"
    local bin="aarch64-elf-gcc"; [[ "$arch" == "arm" ]] && bin="arm-eabi-gcc"
    local out_var="EVA_GCC_ARM64_DIR"; [[ "$arch" == "arm" ]] && out_var="EVA_GCC_ARM_DIR"

    local arc="${CACHE_DIR}/${prefix}-${target_tag}.xz"
    local out_dir="${CACHE_DIR}/${prefix}-${target_tag}"
    local url="https://github.com/${EVA_GCC_REPO}/releases/download/${target_tag}/${prefix}-${target_tag}.xz"

    local old_arc old_tag
    old_arc=$(find "$CACHE_DIR" -maxdepth 1 \
        -name "${prefix}-*.xz" ! -name "${prefix}-${target_tag}.xz" 2>/dev/null | sort -r | head -1)
    old_tag=""; [[ -n "$old_arc" ]] \
        && old_tag="$(basename "$old_arc" | sed "s/${prefix}-\(.*\)\.xz/\1/")"

    if [[ ! -f "$arc" ]]; then
        local arc_tmp="${arc}.tmp" out_dir_tmp="${out_dir}.extracting"
        local ok_new=0

        info "Downloading ${prefix}-${target_tag}.xz..."
        if _download "$url" "$arc_tmp"; then
            info "Extracting ${prefix}-${target_tag}.xz..."
            if _extract "$arc_tmp" "$out_dir_tmp" "$bin"; then
                local test_bin
                test_bin=$(find "$out_dir_tmp" -type f -name "$bin" 2>/dev/null | head -1)
                if [[ -x "$test_bin" ]] && "$test_bin" --version >/dev/null 2>&1; then
                    ok_new=1
                fi
            fi
        fi

        if [[ $ok_new -eq 1 ]]; then
            [[ -n "$old_tag" ]] && {
                warn "Removing old toolchain: ${old_tag}"
                rm -f "$old_arc"
                rm -rf "${CACHE_DIR}/${prefix}-${old_tag}" 2>/dev/null || true
            }
            mv "$arc_tmp" "$arc"
            mv "$out_dir_tmp" "$out_dir"
            ok "Installed: ${prefix}-${target_tag}"
        else
            rm -f "$arc_tmp"; rm -rf "$out_dir_tmp"
            if [[ -n "$old_tag" ]]; then
                warn "New toolchain failed — keeping ${old_tag}"
                arc="${CACHE_DIR}/${prefix}-${old_tag}.xz"
                out_dir="${CACHE_DIR}/${prefix}-${old_tag}"
            else
                err "No valid toolchain available. Abort."
                exit 1
            fi
        fi
    fi

    find "$out_dir" -type f -name "$bin" 2>/dev/null | grep -q . || {
        info "Extracting ${prefix}..."
        _extract "$arc" "$out_dir" "$bin" || { err "Extract failed: $arc"; exit 1; }
    }

    local final_dir; final_dir="$(_find_eva "$prefix" "$bin")"
    eval "$out_var=\"$final_dir\""
    ok "${prefix}: ${!out_var}"
}

fetch_eva_gcc() {
    info "Preparing EVA GCC toolchain..."
    mkdir -p "$CACHE_DIR"

    local target_tag="${EVA_GCC_TAG}"
    if [[ -z "$target_tag" ]]; then
        target_tag="$(_get_latest_tag)"
        if [[ -z "$target_tag" ]]; then
            local fallback
            fallback=$(find "$CACHE_DIR" -maxdepth 1 \
                -name "eva-gcc-arm64-*.xz" 2>/dev/null | sort -r | head -1)
            [[ -n "$fallback" ]] \
                && target_tag="$(basename "$fallback" | sed 's/eva-gcc-arm64-\(.*\)\.xz/\1/')" \
                && warn "Using cached tag: $target_tag" \
                || { err "No release tag and no cache. Abort."; exit 1; }
        fi
    fi
    target_tag=$(echo "$target_tag" | xargs)
    ok "Toolchain tag: $target_tag"

    _fetch_toolchain_arch arm64 "$target_tag"
    _fetch_toolchain_arch arm   "$target_tag"
}

fetch_eva_gcc_offline() {
    info "Offline — searching cache..."
    for arch in arm64 arm; do
        local prefix="eva-gcc-${arch}"
        local bin="aarch64-elf-gcc"; [[ "$arch" == "arm" ]] && bin="arm-eabi-gcc"
        local out_var="EVA_GCC_ARM64_DIR"; [[ "$arch" == "arm" ]] && out_var="EVA_GCC_ARM_DIR"
        local final_dir
        final_dir="$(_find_eva "$prefix" "$bin")" || {
            err "Offline: ${prefix} not found in ${CACHE_DIR}"
            err "Run once without OFFLINE=1 to download toolchain."
            exit 1
        }
        eval "$out_var=\"$final_dir\""
        local tag; tag="$(basename "$final_dir" | sed "s/${prefix}-//")"
        ok "${prefix} (offline): ${!out_var} [${tag}]"
    done
}

# ── Toolchain Detection ───────────────────────────────────────────────────────

detect_toolchains() {
    if [[ -n "$EVA_GCC_ARM64_DIR" && -n "$EVA_GCC_ARM_DIR" ]]; then
        [[ -f "$EVA_GCC_ARM64_DIR/bin/aarch64-elf-gcc" ]] || { err "ARM64 GCC invalid"; exit 1; }
        [[ -f "$EVA_GCC_ARM_DIR/bin/arm-eabi-gcc" ]]      || { err "ARM GCC invalid";   exit 1; }
        ok "Using manual toolchain paths"
        return 0
    fi
    [[ "${OFFLINE}" == "1" ]] && fetch_eva_gcc_offline || fetch_eva_gcc
}

debug_toolchain_info() {
    debug "GCC ARM64 : $("$EVA_GCC_ARM64_DIR/bin/aarch64-elf-gcc" --version 2>/dev/null | head -1)"
    debug "GCC ARM   : $("$EVA_GCC_ARM_DIR/bin/arm-eabi-gcc"      --version 2>/dev/null | head -1)"
    debug "LLD       : $("$EVA_GCC_ARM64_DIR/bin/aarch64-elf-ld.lld" --version 2>/dev/null | head -1 || echo 'not found')"
}

# ── mkdtboimg ─────────────────────────────────────────────────────────────────

download_mkdtboimg() {
    [[ -f "$MKDTBOIMG_SCRIPT" ]] && return 0
    if [[ "${OFFLINE}" == "1" ]]; then
        warn "Offline: mkdtboimg.py not cached — DTBO may not be created"
        return 1
    fi
    local tmp="${MKDTBOIMG_SCRIPT}.tmp"
    if curl -fsSL --connect-timeout 30 --retry 3 "$MKDTBOIMG_URL" \
        | base64 -d > "$tmp" 2>/dev/null \
        && head -5 "$tmp" | grep -qE "python|import|def|class"; then
        mv "$tmp" "$MKDTBOIMG_SCRIPT" && chmod +x "$MKDTBOIMG_SCRIPT"
        ok "mkdtboimg.py ready"
    else
        rm -f "$tmp"
        warn "mkdtboimg.py unavailable — DTBO may not be created"
        return 1
    fi
}

# ── Dependencies ──────────────────────────────────────────────────────────────

check_deps() {
    local pkgs=(make git tar python3 device-tree-compiler flex bison
                libssl-dev curl wget xz-utils bc cpio zip)
    local missing=()
    local installed
    installed=$(dpkg-query -W -f='${Package} ${Status}\n' "${pkgs[@]}" 2>/dev/null \
        | awk '/install ok installed/{print $1}')
    for pkg in "${pkgs[@]}"; do
        echo "$installed" | grep -qx "$pkg" || missing+=("$pkg")
    done
    [[ ${#missing[@]} -gt 0 ]] && {
        warn "Installing: ${missing[*]}"
        sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}"
    }
    for t in make git tar python3 dtc; do
        command -v "$t" >/dev/null 2>&1 || { err "Missing: $t"; exit 1; }
    done
    ok "Dependencies OK"
}

# ── Toolchain Environment ─────────────────────────────────────────────────────

setup_toolchain() {
    export PATH="$EVA_GCC_ARM64_DIR/bin:$EVA_GCC_ARM_DIR/bin:$PATH"
    export CROSS_COMPILE="aarch64-elf-"
    export CROSS_COMPILE_COMPAT="arm-eabi-"
    export LD="aarch64-elf-ld.lld"
    export AR="aarch64-elf-gcc-ar"
    export AS="aarch64-elf-as"
    export NM="aarch64-elf-nm"
    export OBJCOPY="aarch64-elf-objcopy"
    export OBJDUMP="aarch64-elf-objdump"
    export STRIP="aarch64-elf-strip"
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"
    export CC="aarch64-elf-gcc"

    command -v "$LD" >/dev/null 2>&1 || { err "LLD not found"; exit 1; }
    local gcc_ver lld_ver
    gcc_ver="$(aarch64-elf-gcc --version 2>/dev/null | head -1)"
    lld_ver="$(aarch64-elf-ld.lld --version 2>/dev/null | head -1)"
    export KBUILD_COMPILER_STRING="${gcc_ver} + ${lld_ver}"
    export KCONFIG_NOTIMESTAMP=1
    ok "Toolchain ready — CC: ${gcc_ver}"
}

# ── KCFLAGS & KAFLAGS ─────────────────────────────────────────────────────────
# Target : SM7150-AC (732G) — Gold: Kryo 470/A76 @2.3GHz L1D=64K L2=256K
#                              Silver: Kryo 470/A55 @1.8GHz L1D=32K L2=128K
# KAFLAGS: armv8-a+crypto — tidak armv8.2-a (implicitly enable LSE via ARMv8.1)
# LLD -O2: linker optimization level (section merging, ICF), bukan compiler -O2
# Omitted: -fgcse-sm (computed gotos), -falign-* (.org spinlock), -funroll-loops
#          (icache bloat), -fschedule-insns (pre-RA, disabled AArch64 -O2),
#          -fipa-pta (PR88936), -fsection-anchors (KASLR conflict)
_probe_flag() {
    local flag="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    echo "void dummy(void) {}" > "${tmpdir}/probe.c"
    aarch64-elf-gcc "$flag" -Werror -c "${tmpdir}/probe.c" -o "${tmpdir}/probe.o" 2>/dev/null
    local r=$?; rm -rf "$tmpdir"; return $r
}

_probe_ld_flag() {
    local flag="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    printf '.section .text\n.globl _dummy\n_dummy:\n\tret\n' > "${tmpdir}/t.S"
    aarch64-elf-as "${tmpdir}/t.S" -o "${tmpdir}/t.o" 2>/dev/null \
        && "$LD" "$flag" "${tmpdir}/t.o" -o "${tmpdir}/t.out" 2>/dev/null
    local r=$?; rm -rf "$tmpdir"; return $r
}

_populate_lldflags_cache() {
    [[ -n "$_LLDFLAGS_CACHE" ]] && return 0
    local flags=()
    _probe_ld_flag "-O2" && flags+=("-O2") || warn "LLD -O2 not supported, skipping"
    _probe_ld_flag "--sort-section=alignment" \
        && flags+=("--sort-section=alignment") \
        || warn "--sort-section=alignment not supported, skipping"
    _LLDFLAGS_CACHE="${flags[*]}"
}

_populate_kcflags_cache() {
    [[ -n "$_KCFLAGS_CACHE" ]] && return 0

    local flags=(
        "-mcpu=cortex-a76.cortex-a55+crypto"  # big.LITTLE Kryo 470 Gold+Silver
        "-fwrapv"                              # no signed-overflow UB exploit
        "-pipe"                                # pipes antar pass, kurangi I/O
        "--param=l1-cache-size=64"             # Kryo 470 Gold L1D = 64KB
        "--param=l1-cache-line-size=64"        # A76 + A55 line = 64B
        "--param=l2-cache-size=256"            # Kryo 470 Gold L2 = 256KB/core
        "-fweb"                                # false dep elimination, A55 in-order
        "-frename-registers"                   # break false dep setelah RA
        "-fira-loop-pressure"                  # kurangi register spill di loop
        "-fsched-pressure"                     # pressure-aware pre-RA scheduling
        "-flive-range-shrinkage"               # shrink live range sebelum sched
        "-fsched-spec-load"                    # speculative load untuk A76 OoO
        "-fno-allow-store-data-races"          # cegah spurious write ke shared data
        "-Wno-implicit-function-declaration"   # GCC 14+: jadi hard error di gnu89
    )

    # Probed — hanya aktif jika GCC/LLD mendukung
    _probe_flag "-favoid-store-forwarding" \
        && flags+=("-favoid-store-forwarding") \
        || warn "-favoid-store-forwarding not supported, skipping"
    _probe_flag "-fno-stack-clash-protection" \
        && flags+=("-fno-stack-clash-protection") \
        || warn "-fno-stack-clash-protection not supported, skipping"
    _probe_flag "-fsched2-use-superblocks" \
        && flags+=("-fsched2-use-superblocks") \
        || warn "-fsched2-use-superblocks not supported, skipping"
    _probe_flag "-gz=zlib" \
        && flags+=("-gz=zlib") \
        || warn "-gz=zlib not supported, skipping"

    flags+=("-Wno-error")  # harus paling akhir
    _KCFLAGS_CACHE="${flags[*]}"
}

_build_kcflags() {
    [[ -n "$_KCFLAGS_CACHE" ]] || { warn "_KCFLAGS_CACHE empty in subshell — BUG"; return 1; }
    echo "$_KCFLAGS_CACHE"
}

_build_kaflags() {
    echo "-march=armv8-a+crypto"
}

_flags_to_array() {
    local -n _out_ref="$1"
    IFS=' ' read -ra _out_ref <<< "$2"
}

validate_kcflags() {
    local tmpdir; tmpdir=$(mktemp -d)
    echo "void dummy(void) {}" > "${tmpdir}/test.c"
    local -a flag_arr; _flags_to_array flag_arr "$1"
    local stderr
    stderr=$(aarch64-elf-gcc "${flag_arr[@]}" -c "${tmpdir}/test.c" \
        -o "${tmpdir}/test.o" 2>&1 || true)
    rm -rf "$tmpdir"
    if echo "$stderr" | grep -qiE "unknown|unrecognized|invalid|not supported"; then
        err "KCFLAGS validation failed:"; echo "$stderr" >&2; return 1
    fi
    ok "KCFLAGS validated"
}

validate_kaflags() {
    local tmpdir; tmpdir=$(mktemp -d)
    printf '.section .text\n.globl _dummy\n_dummy:\n\tret\n' > "${tmpdir}/test.S"
    local -a flag_arr; _flags_to_array flag_arr "$1"
    local stderr
    stderr=$(aarch64-elf-gcc "${flag_arr[@]}" -c "${tmpdir}/test.S" \
        -o "${tmpdir}/test.o" 2>&1 || true)
    rm -rf "$tmpdir"
    if echo "$stderr" | grep -qiE "unknown|unrecognized|invalid|not supported"; then
        err "KAFLAGS validation failed:"; echo "$stderr" >&2; return 1
    fi
    ok "KAFLAGS validated"
}

# ── Build ─────────────────────────────────────────────────────────────────────

_dtc_wrap() {
    local real="$1" out="$2/dtc_wrapper"
    { echo '#!/usr/bin/env bash'
      printf '"%s" "$@" 2> >(grep -vF ": Warning" >&2)\n' "$real"
      echo 'code=$?; wait; exit $code'
    } > "$out" && chmod +x "$out" && echo "$out"
}

do_clean_build() {
    # ALWAYS CLEAN: hapus out-dir + mrproper sebelum setiap build
    local t0; t0=$(date +%s)
    [[ -d "$OUTDIR" ]] && { info "Removing OUTDIR: $OUTDIR"; rm -rf "$OUTDIR"; }
    make mrproper 2>/dev/null || true
    local args=(O="$OUTDIR" ARCH="$ARCH"
                CROSS_COMPILE="$CROSS_COMPILE"
                CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT")
    make "${args[@]}" "$DEFCONFIG"
    make "${args[@]}" olddefconfig
    ok "Defconfig: $DEFCONFIG ($(_elapsed $t0))"
}

compile_kernel() {
    local abs_out="$OUTDIR"
    [[ "$abs_out" != /* ]] && abs_out="$(pwd)/$abs_out"
    mkdir -p "$abs_out"

    [[ -n "$_KCFLAGS_CACHE" ]] || { err "_KCFLAGS_CACHE empty — _populate_kcflags_cache not called"; return 1; }
    local KCFLAGS="$_KCFLAGS_CACHE"
    local KAFLAGS; KAFLAGS="$(_build_kaflags)"

    local BUILD_TIMESTAMP; BUILD_TIMESTAMP="$(date '+%a %b %d %H:%M:%S %Z %Y')"
    export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
    debug "KCFLAGS : $KCFLAGS"
    debug "KAFLAGS : $KAFLAGS"
    debug "LDFLAGS : $_LLDFLAGS_CACHE"

    local warn_arg=()
    [[ "${WARN_DETAIL}" == "1" ]] && warn_arg=("W=1")

    local ldflags_arg=()
    [[ -n "$_LLDFLAGS_CACHE" ]] && ldflags_arg=("LDFLAGS=$_LLDFLAGS_CACHE")

    local ARGS=(
        -j"$MAKE_PROCS"
        --output-sync=line
        O="$abs_out" ARCH="$ARCH" SUBARCH="$SUBARCH"
        CC="$CC" LD="$LD" AR="$AR" AS="$AS" NM="$NM"
        OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" STRIP="$STRIP"
        CROSS_COMPILE="$CROSS_COMPILE"
        CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT"
        LLVM=0 LLVM_IAS=0
        HOSTCC=gcc HOSTCXX=g++
        HOSTCFLAGS="-O3 -pipe -march=native -fomit-frame-pointer"
        HOSTCXXFLAGS="-O3 -pipe -march=native -fomit-frame-pointer"
        KBUILD_BUILD_USER="$BUILD_USER"
        KBUILD_BUILD_HOST="$BUILD_HOST"
        KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
        KBUILD_BUILD_VERSION=1
        KBUILD_COMPILER_STRING="$KBUILD_COMPILER_STRING"
        KBUILD_VERBOSE=0
        "${ldflags_arg[@]}"
        DTC_FLAGS="-@"
        LOCALVERSION=""
        "${warn_arg[@]}"
    )

    local t1; t1=$(date +%s)
    info "Phase 1/2: scripts, prepare, DTC..."
    make "${ARGS[@]}" scripts prepare || { err "scripts prepare failed"; return 1; }

    local dtc_bin="$abs_out/scripts/dtc/dtc"
    if [[ -x "$dtc_bin" ]]; then
        ok "DTC (internal): $("$dtc_bin" --version 2>&1 | head -1)"
    elif command -v dtc >/dev/null 2>&1; then
        dtc_bin="$(which dtc)"
        warn "DTC (system): $("$dtc_bin" --version 2>&1 | head -1)"
    else
        err "No DTC found. Install device-tree-compiler."; return 1
    fi
    export DTC_EXT="$(_dtc_wrap "$dtc_bin" "$abs_out/scripts/dtc")"

    ok "Phase 1 done ($(_elapsed $t1))"

    local t2; t2=$(date +%s)
    info "Phase 2/2: Image.gz-dtb..."
    make "${ARGS[@]}" KCFLAGS="$KCFLAGS" KAFLAGS="$KAFLAGS" DTC="$DTC_EXT" Image.gz-dtb 2>&1 \
        || return 1
    ok "Phase 2 done ($(_elapsed $t2))"

    local image="$abs_out/arch/arm64/boot/Image.gz-dtb"
    [[ -f "$image" ]] || { err "Image.gz-dtb not found!"; return 1; }
    local size; size=$(stat -c%s "$image")
    ok "Built: $(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size} bytes")"
    local krel="$abs_out/include/config/kernel.release"
    [[ -f "$krel" ]] && ok "Version: $(cat "$krel")"
    OUTDIR="$abs_out"
}

# ── Warnings ──────────────────────────────────────────────────────────────────

count_warnings() {
    local log="${1:-$LOGFILE}"
    [[ -f "$log" ]] || { echo "0"; return; }
    # Pattern GCC diagnostic presisi (file:line:col: warning:) — hindari
    # false-positive dari string biasa yang kebetulan mengandung ': warning:'
    grep -cP ':\d+:\d+: warning:' "$log" 2>/dev/null || echo "0"
}

_extract_warnings() {
    [[ -f "$LOGFILE" ]] || return 0
    awk '
        /^  [A-Z][A-Z0-9_]+ / {
            if (has_warn) print block "\n"
            block = $0
            has_warn = 0
            next
        }
        /: warning:/ { has_warn = 1 }
        { block = (block == "") ? $0 : block "\n" $0 }
        END { if (has_warn) print block "\n" }
    ' "$LOGFILE" > "$WARN_FILE" 2>/dev/null || true
}

summarize_warnings() {
    _extract_warnings

    local total; total=$(count_warnings "$LOGFILE")

    if [[ "$total" -eq 0 ]]; then
        ok "No warnings — clean build!"
        return
    fi

    {
        printf '\n'
        printf '── Top files by warning count (%d total) ──\n' "$total"
        grep -oP '^[^:]+(?=:\d+:\d+: warning:)' "$WARN_FILE" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -15 \
            | awk '{printf "  %5d  %s\n", $1, $2}'
        printf '\n'
        printf '  raw : %s\n' "$WARN_FILE"
        printf '  log : %s\n' "$LOGFILE"
        printf '\n'
    } >&2
}

# ── DTBO ──────────────────────────────────────────────────────────────────────

build_dtbo() {
    local dtb_dir="$OUTDIR/arch/arm64/boot/dts/qcom"
    local out_dtbo="$OUTDIR/dtbo.img"
    shopt -s nullglob; local files=("$dtb_dir"/*.dtbo); shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "No .dtbo files — dtbo.img will be empty"; : > "$out_dtbo"; return
    fi
    [[ -f "$MKDTBOIMG_SCRIPT" ]] && command -v python3 >/dev/null 2>&1 \
        && python3 "$MKDTBOIMG_SCRIPT" create "$out_dtbo" "${files[@]}" 2>/dev/null \
        && { ok "dtbo.img (${#files[@]} files)"; return; }
    warn "mkdtboimg.py unavailable — concatenating"
    cat "${files[@]}" > "$out_dtbo"
}

# ── Packaging ─────────────────────────────────────────────────────────────────

prepare_anykernel() {
    if [[ ! -d "$ANYKERNEL_DIR" ]]; then
        [[ "${OFFLINE}" == "1" ]] && {
            err "Offline: AnyKernel3 not found at ${ANYKERNEL_DIR}"
            err "Run once without OFFLINE=1 to clone it."; return 1
        }
        git clone --depth=1 --branch "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$ANYKERNEL_DIR" 2>/dev/null \
        || git clone --depth=1 "$ANYKERNEL_REPO" "$ANYKERNEL_DIR" 2>/dev/null \
        || { err "Failed to clone AnyKernel3"; return 1; }
        ok "AnyKernel3 cloned"
    else
        [[ "${OFFLINE}" == "1" ]] && { ok "AnyKernel3 (cached)"; return 0; }
        ( cd "$ANYKERNEL_DIR"
          git fetch --depth=1 origin "$ANYKERNEL_BRANCH" 2>/dev/null || true
          git reset --hard "origin/$ANYKERNEL_BRANCH" 2>/dev/null \
              || git reset --hard "FETCH_HEAD" 2>/dev/null \
              || warn "AnyKernel3 reset failed — using existing state" )
    fi
}

package_anykernel() {
    prepare_anykernel || return 1
    local image="$OUTDIR/arch/arm64/boot/Image.gz-dtb"
    [[ -f "$image" ]] || { err "Image.gz-dtb not found"; return 1; }
    cp "$image" "$ANYKERNEL_DIR/"
    local dtbo="$OUTDIR/dtbo.img"
    [[ -f "$dtbo" && -s "$dtbo" ]] && cp "$dtbo" "$ANYKERNEL_DIR/" || true
    ( cd "$ANYKERNEL_DIR"
      rm -f ./*.zip
      zip -r9 "$ZIPNAME" . --exclude ".git/*" --exclude "*.git*" --exclude "*.zip" \
    ) || { err "zip failed"; return 1; }
    [[ -f "$ANYKERNEL_DIR/$ZIPNAME" ]] || { err "Zip not found after packaging"; return 1; }
    mv "$ANYKERNEL_DIR/$ZIPNAME" "$SCRIPT_DIR/"
    local sz; sz=$(stat -c%s "$SCRIPT_DIR/$ZIPNAME")
    ok "Zip: $SCRIPT_DIR/$ZIPNAME ($(numfmt --to=iec-i --suffix=B "$sz" 2>/dev/null || echo "${sz} bytes"))"
}

# ── GNU Make Compatibility ────────────────────────────────────────────────────
# GNU Make 4.4+ memecah parse Kbuild CAF 4.14 (techpack/audio):
#   scripts/Makefile.lib:374: *** prerequisites cannot be defined in recipes
# Build 4.14 butuh make < 4.4. Fungsi ini memaksa make 4.3 jika perlu.

_MAKE43_DIR="${CACHE_DIR}/make-4.3"

_make_version_check() {
    local v maj min
    v=$(make --version 2>/dev/null | head -1 | sed -n 's/^GNU Make \([0-9]*\)\.\([0-9]*\).*/\1.\2/p')
    [[ -z "$v" ]] && return 1
    maj="${v%%.*}"; min="${v##*.}"
    if (( maj > 4 || (maj == 4 && min >= 4) )); then
        return 1
    fi
    return 0
}

ensure_make_compat() {
    command -v make >/dev/null 2>&1 || { warn "make belum ada — akan diinstall check_deps"; return 0; }
    if _make_version_check; then
        debug "GNU Make $(make --version 2>/dev/null | head -1 | sed 's/^GNU Make //') — OK"
        return 0
    fi

    warn "GNU Make 4.4+ merusak parse Kbuild 4.14 techpack (prerequisites cannot be defined in recipes)"
    warn "Menggunakan GNU Make 4.3..."

    if [[ -x "$_MAKE43_DIR/bin/make" ]]; then
        ok "GNU Make 4.3 cached: $_MAKE43_DIR"
    elif [[ "${OFFLINE}" == "1" ]]; then
        err "GNU Make 4.3 tidak ter-cache di ${_MAKE43_DIR}"
        err "Jalankan sekali tanpa OFFLINE=1 untuk build otomatis, atau downgrade make."
        exit 1
    else
        command -v cc >/dev/null 2>&1 || { err "Tidak ada cc — install build-essential dulu"; exit 1; }
        info "Download & build GNU Make 4.3..."
        local tmpdir; tmpdir=$(mktemp -d)
        local url="https://ftp.gnu.org/gnu/make/make-4.3.tar.gz"
        if ! _download "$url" "$tmpdir/make-4.3.tar.gz"; then
            rm -rf "$tmpdir"; err "Gagal download make-4.3.tar.gz"; exit 1
        fi
        ( cd "$tmpdir"
          tar xzf make-4.3.tar.gz
          cd make-4.3
          ./configure --prefix="$_MAKE43_DIR" >/dev/null 2>&1 \
              && make -j"$MAKE_PROCS" >/dev/null 2>&1 \
              && make install >/dev/null 2>&1 ) \
            || { rm -rf "$tmpdir"; err "Gagal build GNU Make 4.3"; exit 1; }
        rm -rf "$tmpdir"
        ok "GNU Make 4.3 terpasang: $_MAKE43_DIR"
    fi

    export PATH="$_MAKE43_DIR/bin:$PATH"
    make --version 2>/dev/null | grep -q "GNU Make 4.3" \
        || { err "make 4.3 masih belum aktif di PATH"; exit 1; }
    ok "GNU Make 4.3 aktif — $(make --version 2>/dev/null | head -1)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    _validate_early
    check_deps
    ensure_make_compat
    _cleanup_stale_temps
    detect_toolchains
    debug_toolchain_info
    download_mkdtboimg
    setup_toolchain

    _populate_kcflags_cache
    _populate_lldflags_cache
    validate_kcflags "$(_build_kcflags)"
    validate_kaflags "$(_build_kaflags)"

    # ALWAYS CLEAN — rm OUTDIR + make mrproper, tanpa kondisi
    do_clean_build

    if compile_kernel; then
        build_dtbo
        package_anykernel
        summarize_warnings

        local warn_count; warn_count=$(count_warnings "$LOGFILE")
        ok "============================================================"
        ok " BUILD SUCCESS — Farewell-EXT"
        ok " Device  : Poco X3 NFC (surya) | SM7150-AC (732G) | Samsung 8nm LPP"
        ok " CPU     : 2× Kryo 470 Gold (A76) @2.3GHz | 6× Kryo 470 Silver (A55) @1.8GHz"
        ok " Tune    : cortex-a76.cortex-a55+crypto (no LSE)"
        ok "           fsched-pressure | fsched-spec-load | fsched2-use-superblocks"
        ok "           fweb | frename-registers | fira-loop-pressure | flive-range-shrinkage"
        ok "           fno-allow-store-data-races | favoid-store-forwarding (if supported)"
        ok "           fno-stack-clash-protection (if supported)"
        ok "           L1D=64KB | L2=256KB (Kryo 470 Gold) | line=64B"
        ok " KAFLAGS : armv8-a+crypto (no LSE) | LLD: ${_LLDFLAGS_CACHE:-(no extra flags)}"
        ok " offline : ${OFFLINE} | warn_detail=${WARN_DETAIL} | HOSTCC: O3+native"
        ok " Output  : $ZIPNAME"
        ok " Time    : $(_elapsed "$BUILD_START") WIB"
        ok " Warnings: ${warn_count}"
        ok "============================================================"
        [[ "$warn_count" -gt 0 ]] && info " ${warn_count} warnings — lihat ${WARN_FILE}"
    else
        err "Build failed — see ${LOGFILE}"; exit 1
    fi
}

main