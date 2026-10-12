#!/usr/bin/env bash
set -euo pipefail

# build-gcc.sh — Kernel builder for POCO X3 NFC (surya) — varian GCC big.LITTLE
# Kernel 4.14 (CAF, SM7150)
# Toolchain: GCC — big.LITTLE Cortex-A76.Cortex-A55 (SM7150 = 2x A76 + 6x A55)
#   Default   : EVA GCC (mvaisakh/gcc-build) — bare-metal GCC + LLD
#   Alternatif: ARM GNU toolchain resmi, contoh:
#     GCC_DIR=/path/arm-gnu-toolchain-14.3-x86_64-aarch64-none-linux-gnu \
#     GCC_PREFIX=aarch64-none-linux-gnu- bash build-gcc.sh
#   + dtc prebuilt AOSP via DTC_EXT (untuk overlay dtbo, cara Pixel sunfish)
#
# Pemakaian:
#   bash build-gcc.sh                    # clean build + zip flashable
#   INCREMENTAL=1 bash build-gcc.sh      # incremental (tanpa hapus out/)
#   PACKAGE=0 bash build-gcc.sh          # build kernel saja (tanpa zip)
#   CCACHE=0 bash build-gcc.sh           # matikan ccache
#   EVA_GCC_TAG=latest bash build-gcc.sh # pakai rilis EVA GCC terbaru
#
# Hasil: build-artifacts/{log.txt,warnings.txt,Image.gz-dtb,dtbo.img} + <nama>.zip

export TZ="${TZ:-Asia/Jakarta}"

# ── Konfigurasi ───────────────────────────────────────────────────────────────

KERNEL_NAME="${KERNEL_NAME:-Farewell-EXT}"
DEFCONFIG="${DEFCONFIG:-surya_defconfig}"
OUTDIR="${OUTDIR:-out-gcc}"
ARCH="${ARCH:-arm64}"
BUILD_USER="${BUILD_USER:-Fannndi}"
BUILD_HOST="${BUILD_HOST:-$(hostname 2>/dev/null || echo linux)}"
MAKE_PROCS="${MAKE_PROCS:-$(nproc)}"
BUILD_START=$(date +%s)

INCREMENTAL="${INCREMENTAL:-0}"
PACKAGE="${PACKAGE:-1}"
WARN_DETAIL="${WARN_DETAIL:-1}"
OFFLINE="${OFFLINE:-0}"
CCACHE="${CCACHE:-auto}"

# Toolchain GCC — default EVA GCC (bare-metal GCC + LLD)
GCC_PREFIX="${GCC_PREFIX:-aarch64-elf-}"
GCC_DIR="${GCC_DIR:-}"
EVA_GCC_REPO="${EVA_GCC_REPO:-mvaisakh/gcc-build}"
EVA_GCC_TAG="${EVA_GCC_TAG:-01102026}"   # rilis EVA GCC terbaru; "latest" = auto-cek API
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$HOME/toolchains}"

# binutils Linux untuk LINKING — BFD ld mendukung emulasi 'aarch64linux'
# (EVA BFD itu bare-metal: tidak; EVA gold 1.16: internal error di kernel 4.14).
# Default: prebuilt AOSP aarch64-linux-android-4.9.
BINUTILS_DIR="${BINUTILS_DIR:-$TOOLCHAIN_ROOT/aarch64-linux-android-4.9}"
BINUTILS_REPO="${BINUTILS_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9}"

# Linker utama: binutils resmi GNU (ftp.gnu.org), dibangun dari sumber (target
# aarch64-linux-gnu). Default 2.47 (2026) — DIDUKUNG berkat patch kernel di
# branch ini (gsi __packed, RTIC lds, kbuild member archive, script initcall).
# Tanpa patch tsb, kernel arm64 < 4.19 hanya bisa di-link binutils <= 2.29
# (bug 22764: >= 2.30 gagal "dangerous relocation" di ksymtab).
BINUTILS_GNU_VER="${BINUTILS_GNU_VER:-2.47}"
BINUTILS_GNU_DIR="${BINUTILS_GNU_DIR:-$TOOLCHAIN_ROOT/binutils-gnu-$BINUTILS_GNU_VER}"
BINUTILS_GNU_URL="${BINUTILS_GNU_URL:-https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_GNU_VER}.tar.xz}"

BINUTILS_LD=""

# dtc eksternal — cara Pixel sunfish (build.config.common: DTC_EXT=prebuilts-master/misc/linux-x86/dtc)
# dtc internal 1.4.4 tidak bisa compile overlay /plugin/ dengan referensi label
# yang belum terdefinisi (&soc { }), prebuilt AOSP dtc bisa.
DTC_BIN="${DTC_BIN:-}"
DTC_URL="${DTC_URL:-https://android.googlesource.com/platform/prebuilts/misc/+/refs/heads/master/linux-x86/dtc/dtc?format=TEXT}"

# AnyKernel3 packaging
ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/fannndi/Kernel_Zip}"
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-Farewell}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/toolchains}"
ANYKERNEL_DIR="${CACHE_DIR}/AnyKernel3"
ARTIFACT_DIR="build-artifacts"
LOGFILE="${ARTIFACT_DIR}/log.txt"
WARN_FILE="${ARTIFACT_DIR}/warnings.txt"
ZIPNAME="${KERNEL_NAME// /_}-GCC-$(date '+%d%m%Y-%H%M').zip"

_KCFLAGS_CACHE=""
_LLDFLAGS_CACHE=""

# Shim `python` (beberapa script kernel memanggil python, bukan python3)
if ! command -v python &>/dev/null && command -v python3 &>/dev/null; then
    mkdir -p "$CACHE_DIR/bin"
    ln -sf "$(command -v python3)" "$CACHE_DIR/bin/python"
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
    [[ $code -ne 0 ]] && err "Build gagal. Cek ${LOGFILE} untuk detail."
    exit $code
}
trap '_on_exit' ERR SIGINT SIGTERM

info "Kernel Builder — POCO X3 NFC (surya) | 4.14 CAF | GCC big.LITTLE (A76.A55)"
info "Mode: $([[ "$INCREMENTAL" == "1" ]] && echo incremental || echo clean) | jobs=${MAKE_PROCS} | TZ=${TZ}"

# ── Validasi awal ─────────────────────────────────────────────────────────────

_validate_early() {
    [[ -f "Makefile" ]] || { err "Makefile tidak ditemukan — jalankan dari root kernel."; exit 1; }
    [[ -f "arch/${ARCH}/configs/${DEFCONFIG}" ]] || { err "Defconfig tidak ada: arch/${ARCH}/configs/${DEFCONFIG}"; exit 1; }
    ok "Source OK — arch/${ARCH}/configs/${DEFCONFIG}"
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
    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Package kurang: ${missing[*]} — coba install via apt..."
        sudo apt-get update -qq && sudo apt-get install -y "${missing[@]}" \
            || { err "Gagal install: ${missing[*]}"; exit 1; }
    fi
    for t in make git tar python3 zip; do
        command -v "$t" >/dev/null 2>&1 || { err "Tidak ada: $t"; exit 1; }
    done
    # dtc sistem opsional — kernel 4.14 build dtc internal (scripts/dtc)
    if command -v dtc >/dev/null 2>&1; then
        debug "dtc sistem: $(dtc --version 2>&1 | head -1)"
    else
        debug "dtc sistem tidak ada — pakai dtc internal (scripts/dtc)"
    fi
    ok "Dependencies OK"
}

# ── GNU Make compatibility ────────────────────────────────────────────────────
# GNU Make 4.4+ gagal parse Kbuild CAF 4.14 (techpack):
#   "prerequisites cannot be defined in recipes"
# Paksa GNU Make 4.3 bila versi sistem >= 4.4.

_MAKE43_DIR="${CACHE_DIR}/make-4.3"

_download() {
    local url="$1" out="$2"
    for _ in 1 2 3; do
        command -v wget >/dev/null 2>&1 && wget -q --show-progress -O "$out" "$url" && return 0
        command -v curl >/dev/null 2>&1 && curl -L -o "$out" --fail --progress-bar --retry 3 "$url" && return 0
        sleep 3
    done
    return 1
}

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
    command -v make >/dev/null 2>&1 || { warn "make belum ada — akan dicek di check_deps"; return 0; }
    if _make_version_check; then
        debug "GNU Make $(make --version | head -1 | sed 's/^GNU Make //') — OK"
        return 0
    fi

    warn "GNU Make 4.4+ merusak parse Kbuild 4.14 (techpack) — memakai GNU Make 4.3"
    if [[ -x "$_MAKE43_DIR/bin/make" ]]; then
        ok "GNU Make 4.3 cached: $_MAKE43_DIR"
    else
        command -v cc >/dev/null 2>&1 || { err "Tidak ada cc — install build-essential"; exit 1; }
        info "Download & build GNU Make 4.3..."
        local tmpdir; tmpdir=$(mktemp -d)
        if ! _download "https://ftp.gnu.org/gnu/make/make-4.3.tar.gz" "$tmpdir/make-4.3.tar.gz"; then
            rm -rf "$tmpdir"; err "Gagal download make-4.3.tar.gz"; exit 1
        fi
        ( cd "$tmpdir" && tar xzf make-4.3.tar.gz && cd make-4.3 \
          && ./configure --prefix="$_MAKE43_DIR" >/dev/null 2>&1 \
          && make -j"$MAKE_PROCS" >/dev/null 2>&1 \
          && make install >/dev/null 2>&1 ) \
            || { rm -rf "$tmpdir"; err "Gagal build GNU Make 4.3"; exit 1; }
        rm -rf "$tmpdir"
        ok "GNU Make 4.3 terpasang: $_MAKE43_DIR"
    fi

    export PATH="$_MAKE43_DIR/bin:$PATH"
    make --version 2>/dev/null | grep -q "GNU Make 4.3" \
        || { err "make 4.3 belum aktif di PATH"; exit 1; }
    ok "GNU Make 4.3 aktif"
}

# ── EVA GCC (default) ─────────────────────────────────────────────────────────

_get_latest_tag() {
    local url="https://api.github.com/repos/${EVA_GCC_REPO}/releases/latest"
    local raw=""
    command -v curl >/dev/null 2>&1 && raw=$(curl -fsSL --max-time 20 "$url" 2>/dev/null || true)
    command -v wget >/dev/null 2>&1 && [[ -z "$raw" ]] \
        && raw=$(wget -qO- --timeout=20 "$url" 2>/dev/null || true)
    echo "$raw" | grep -q 'rate limit' && { warn "GitHub rate limited"; echo ""; return 0; }
    local tag=""
    command -v jq >/dev/null 2>&1 \
        && tag=$(echo "$raw" | jq -r '.tag_name // empty' 2>/dev/null) \
        || tag=$(echo "$raw" | grep '"tag_name"' | head -1 \
            | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    echo "$tag" | tr -d '\r\n' | xargs
}

_find_eva_bin() {
    local dir="$1" bin="$2"
    find "$dir" -maxdepth 4 -type f -name "$bin" 2>/dev/null | head -1
}

fetch_eva_gcc() {
    local tag="$EVA_GCC_TAG"
    if [[ "$tag" == "latest" || -z "$tag" ]]; then
        tag="$(_get_latest_tag)"
        if [[ -z "$tag" ]]; then
            warn "Gagal cek tag terbaru EVA GCC"
            return 1
        fi
    fi

    local arc="${TOOLCHAIN_ROOT}/eva-gcc-arm64-${tag}.xz"
    local out_dir="${TOOLCHAIN_ROOT}/eva-gcc-arm64-${tag}"
    local url="https://github.com/${EVA_GCC_REPO}/releases/download/${tag}/eva-gcc-arm64-${tag}.xz"

    if [[ -n "$(_find_eva_bin "$out_dir" 'aarch64-elf-gcc')" ]]; then
        return 0
    fi
    if [[ "$OFFLINE" == "1" ]]; then
        warn "Offline: EVA GCC tidak ada di cache ($out_dir)"
        return 1
    fi

    if [[ ! -f "$arc" ]]; then
        info "Download EVA GCC ${tag} (~643MB, sekali saja)..."
        if ! _download "$url" "${arc}.tmp"; then
            rm -f "${arc}.tmp"
            warn "Gagal download: $url"
            return 1
        fi
        mv "${arc}.tmp" "$arc"
    fi

    info "Extract EVA GCC ${tag}..."
    rm -rf "${out_dir}.extracting"
    mkdir -p "${out_dir}.extracting"
    if ! tar -xf "$arc" -C "${out_dir}.extracting" 2>/dev/null; then
        xz -dk "$arc" -c > "${arc%.xz}.tar" 2>/dev/null \
            && tar -xf "${arc%.xz}.tar" -C "${out_dir}.extracting" \
            && rm -f "${arc%.xz}.tar"
    fi
    if [[ -z "$(_find_eva_bin "${out_dir}.extracting" 'aarch64-elf-gcc')" ]]; then
        rm -rf "${out_dir}.extracting"
        warn "Extract gagal / binari tidak ditemukan"
        return 1
    fi
    rm -rf "$out_dir"
    mv "${out_dir}.extracting" "$out_dir"
    ok "EVA GCC siap: $out_dir"
    return 0
}

_fetch_binutils() {
    if [[ -x "$BINUTILS_DIR/bin/aarch64-linux-android-ld" ]]; then
        return 0
    fi
    if [[ "$OFFLINE" == "1" ]]; then
        warn "Offline: binutils tidak ada di $BINUTILS_DIR"
        return 1
    fi
    info "Download binutils aarch64-linux-android-4.9 (git clone --depth=1)..."
    mkdir -p "$(dirname "$BINUTILS_DIR")"
    local tmp="${BINUTILS_DIR}.extracting"
    rm -rf "$tmp"
    if git clone --depth=1 --quiet "$BINUTILS_REPO" "$tmp" 2>/dev/null; then
        rm -rf "$BINUTILS_DIR"
        mv "$tmp" "$BINUTILS_DIR"
        ok "binutils siap: $BINUTILS_DIR"
        return 0
    fi
    rm -rf "$tmp"
    warn "Gagal download binutils: $BINUTILS_REPO"
    return 1
}

# Binutils resmi GNU (terbaru) — build dari sumber, target aarch64-linux-gnu.
# Hasil: $BINUTILS_GNU_DIR/bin/aarch64-linux-gnu-* (host x86_64).
_prepare_binutils_gnu() {
    [[ -x "$BINUTILS_GNU_DIR/bin/aarch64-linux-gnu-ld" ]] && return 0
    [[ "$OFFLINE" == "1" ]] && return 1
    command -v make >/dev/null 2>&1 && command -v cc >/dev/null 2>&1 || return 1
    info "Bangun GNU binutils $BINUTILS_GNU_VER dari sumber (sekali saja, ~10 menit)..."
    local work="$TOOLCHAIN_ROOT/binutils-$BINUTILS_GNU_VER"
    mkdir -p "$TOOLCHAIN_ROOT"
    if [[ ! -f "$work.tar.xz" ]]; then
        if ! _download "$BINUTILS_GNU_URL" "$work.tar.xz"; then
            warn "Gagal download binutils GNU ($BINUTILS_GNU_URL)"
            return 1
        fi
    fi
    rm -rf "$work"
    if ! tar xf "$work.tar.xz" -C "$TOOLCHAIN_ROOT" 2>/dev/null; then
        warn "Gagal extract binutils GNU"; return 1
    fi
    if ( cd "$work" && mkdir -p build && cd build \
         && ../configure --target=aarch64-linux-gnu --prefix="$BINUTILS_GNU_DIR" \
                --disable-nls --disable-werror --disable-shared --disable-gdb --disable-sim \
                --disable-gprofng --disable-gold --disable-libdecnumber --without-zstd \
                > configure.log 2>&1 \
         && make -j"$MAKE_PROCS" all-ld all-binutils > make.log 2>&1 \
         && make install-ld install-binutils > install.log 2>&1 ); then
        rm -rf "$work" "$work.tar.xz"
    else
        warn "Gagal build binutils GNU (lihat $work/build/*.log)"
        return 1
    fi
    [[ -x "$BINUTILS_GNU_DIR/bin/aarch64-linux-gnu-ld" ]]
}

# ── Toolchain ─────────────────────────────────────────────────────────────────

find_toolchains() {
    mkdir -p "$TOOLCHAIN_ROOT"

    if [[ -z "$GCC_DIR" ]]; then
        # pakai cache eva-gcc-arm64-* terbaru (tag berbasis tanggal, sort aman)
        GCC_DIR="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'eva-gcc-arm64-*' ! -name '*.extracting' 2>/dev/null | sort -r | head -1 || true)"
    fi
    if [[ -z "$GCC_DIR" ]]; then
        fetch_eva_gcc || true
        GCC_DIR="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'eva-gcc-arm64-*' ! -name '*.extracting' 2>/dev/null | sort -r | head -1 || true)"
    fi

    # Resolusi root toolchain: bin/ langsung, atau nested ala EVA (<root>/gcc-arm64/bin/)
    local resolved="" hit=""
    if [[ -n "$GCC_DIR" && -x "$GCC_DIR/bin/${GCC_PREFIX}gcc" ]]; then
        resolved="$GCC_DIR"
    elif [[ -n "$GCC_DIR" ]]; then
        hit=$(find "$GCC_DIR" -maxdepth 4 -type f -name "${GCC_PREFIX}gcc" 2>/dev/null | head -1 || true)
        if [[ -n "$hit" ]]; then
            resolved="$(dirname "$(dirname "$hit")")"
        fi
    fi

    # auto-deteksi prefix (mis. toolchain ARM GNU)
    if [[ -z "$resolved" && -n "$GCC_DIR" ]]; then
        hit=$(find "$GCC_DIR" -maxdepth 4 -type f -name '*-gcc' 2>/dev/null | head -1 || true)
        if [[ -n "$hit" ]]; then
            GCC_PREFIX="$(basename "$hit" | sed 's/gcc$//')"
            resolved="$(dirname "$(dirname "$hit")")"
            warn "Prefix terdeteksi otomatis: $GCC_PREFIX"
        fi
    fi

    if [[ -z "$resolved" || ! -x "$resolved/bin/${GCC_PREFIX}gcc" ]]; then
        err "GCC tidak ditemukan (prefix: ${GCC_PREFIX})."
        err "Set GCC_DIR=/path/ke/toolchain (mis. ARM GNU) atau biarkan kosong untuk EVA GCC."
        exit 1
    fi
    GCC_DIR="$resolved"
    ok "GCC    : $("$GCC_DIR/bin/${GCC_PREFIX}gcc" --version 2>/dev/null | head -1)"
    ok "Lokasi : $GCC_DIR"

    # Linker: GNU binutils terbaru (dibangun dari sumber, sekali) — didukung
    # berkat patch kernel di branch ini. Fallback: prebuilt AOSP 4.9 (2.27).
    _prepare_binutils_gnu || true
    if [[ -x "$BINUTILS_GNU_DIR/bin/aarch64-linux-gnu-ld" ]]; then
        BINUTILS_LD="$BINUTILS_GNU_DIR/bin/aarch64-linux-gnu-ld"
        ok "binutils: $("$BINUTILS_LD" --version 2>/dev/null | head -1) (GNU $BINUTILS_GNU_VER)"
    else
        _fetch_binutils || true
        if [[ -x "$BINUTILS_DIR/bin/aarch64-linux-android-ld" ]]; then
            BINUTILS_LD="$BINUTILS_DIR/bin/aarch64-linux-android-ld"
            ok "binutils: $("$BINUTILS_LD" --version 2>/dev/null | head -1) (AOSP 4.9)"
        else
            warn "binutils Linux tidak ada — fallback linker dari EVA GCC"
        fi
    fi
    return 0
}

setup_env() {
    export PATH="$GCC_DIR/bin:$PATH"
    export ARCH="$ARCH"
    export CROSS_COMPILE="$GCC_PREFIX"
    export CC_BASE="${GCC_PREFIX}gcc"
    export AR="${GCC_PREFIX}gcc-ar"
    export AS="${GCC_PREFIX}as"
    export NM="${GCC_PREFIX}nm"
    export OBJCOPY="${GCC_PREFIX}objcopy"
    export OBJDUMP="${GCC_PREFIX}objdump"
    export STRIP="${GCC_PREFIX}strip"

    # Linker: prioritas BFD ld dari binutils Linux (emulasi 'aarch64linux',
    # aman untuk kernel 4.14 + MODVERSIONS — kombinasi sama dengan build clang).
    # Urutan: binutils Ubuntu 2.4x (terbaru) → AOSP 4.9 → LLD EVA (USE_LLD=1)
    #         → gold EVA → BFD EVA.
    if [[ -n "${BINUTILS_LD:-}" && -x "$BINUTILS_LD" ]]; then
        export LD="$BINUTILS_LD"
    elif [[ "${USE_LLD:-0}" == "1" ]] && command -v "${GCC_PREFIX}ld.lld" >/dev/null 2>&1; then
        export LD="${GCC_PREFIX}ld.lld"
    elif command -v "${GCC_PREFIX}ld.gold" >/dev/null 2>&1; then
        export LD="${GCC_PREFIX}ld.gold"
    else
        export LD="${GCC_PREFIX}ld"
    fi

    export HOSTCC=gcc HOSTCXX=g++
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"
    export KCONFIG_NOTIMESTAMP=1

    # dtc eksternal (cara Pixel) — dipakai kernel lewat DTC_EXT
    if [[ -n "${DTC_BIN:-}" ]]; then
        export DTC_EXT="$DTC_BIN"
    fi

    # ccache (default: aktif bila tersedia)
    if [[ "$CCACHE" != "0" ]] && command -v ccache >/dev/null 2>&1; then
        export CC="ccache $CC_BASE"
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        mkdir -p "$CCACHE_DIR"
        ok "ccache : aktif ($CCACHE_DIR)"
    else
        export CC="$CC_BASE"
    fi

    command -v "$LD" >/dev/null 2>&1 || { err "Linker tidak ditemukan: $LD"; exit 1; }
    local gcc_ver ld_ver
    gcc_ver="$("$GCC_DIR/bin/$CC_BASE" --version 2>/dev/null | head -1)"
    ld_ver="$("$LD" --version 2>/dev/null | head -1)"
    export KBUILD_COMPILER_STRING="${gcc_ver} + ${ld_ver}"
    ok "Linker : ${ld_ver}"
    ok "Environment siap (GCC big.LITTLE A76.A55)"
}

# ── KCFLAGS / KAFLAGS (big.LITTLE tuning) ─────────────────────────────────────
# Target : SM7150 — 2x Kryo 470 Gold (A76) @2.3GHz L1D=64K L2=256K
#                    6x Kryo 470 Silver (A55) @1.8GHz L1D=32K L2=128K
# -mcpu=cortex-a76.cortex-a55: big.LITTLE tuning GCC (docs: AArch64 Options)
# KAFLAGS: armv8-a+crypto — tidak armv8.2-a (hindari LSE implisit via ARMv8.1)

_probe_flag() {
    local flag="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    echo "void dummy(void) {}" > "${tmpdir}/probe.c"
    "$CC_BASE" "$flag" -Werror -c "${tmpdir}/probe.c" -o "${tmpdir}/probe.o" 2>/dev/null
    local r=$?; rm -rf "$tmpdir"; return $r
}

_probe_ld_flag() {
    local flag="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    printf '.section .text\n.globl _dummy\n_dummy:\n\tret\n' > "${tmpdir}/t.S"
    "$AS" "${tmpdir}/t.S" -o "${tmpdir}/t.o" 2>/dev/null \
        && "$LD" "$flag" "${tmpdir}/t.o" -o "${tmpdir}/t.out" 2>/dev/null
    local r=$?; rm -rf "$tmpdir"; return $r
}

_populate_kcflags_cache() {
    [[ -n "$_KCFLAGS_CACHE" ]] && return 0

    local flags=(
        "-mcpu=cortex-a76.cortex-a55+crypto"   # big.LITTLE: A76 + A55 sekaligus
        "-fwrapv"                              # no signed-overflow UB
        "-pipe"                                # kurangi I/O antar pass
        "--param=l1-cache-size=64"             # Kryo 470 Gold L1D = 64KB
        "--param=l1-cache-line-size=64"        # A76 + A55 line = 64B
        "--param=l2-cache-size=256"            # Kryo 470 Gold L2 = 256KB/core
        "-fweb"                                # false dep elimination, A55 in-order
        "-frename-registers"                   # break false dep setelah RA
        "-fira-loop-pressure"                  # kurangi spill di loop
        "-fsched-pressure"                     # pressure-aware scheduling
        "-flive-range-shrinkage"               # shrink live range sebelum sched
        "-fsched-spec-load"                    # speculative load untuk A76 OoO
        "-fno-allow-store-data-races"          # cegah spurious write ke shared data
        "-Wno-implicit-function-declaration"   # GCC 14+: jadi hard error di gnu89
    )

    _probe_flag "-favoid-store-forwarding" \
        && flags+=("-favoid-store-forwarding") \
        || warn "-favoid-store-forwarding tidak didukung, skip"
    _probe_flag "-fno-stack-clash-protection" \
        && flags+=("-fno-stack-clash-protection") \
        || warn "-fno-stack-clash-protection tidak didukung, skip"
    _probe_flag "-fsched2-use-superblocks" \
        && flags+=("-fsched2-use-superblocks") \
        || warn "-fsched2-use-superblocks tidak didukung, skip"

    # CATATAN: '-gz=zlib' sengaja TIDAK dipakai — bikin debug section
    # terkompresi (SHF_COMPRESSED) yang binutils 2.27 (linker kita) tidak
    # bisa decompress ("unable to initialize decompress status").

    flags+=("-Wno-error")  # harus paling akhir
    _KCFLAGS_CACHE="${flags[*]}"
    return 0
}

_populate_ldflags_cache() {
    [[ -n "$_LLDFLAGS_CACHE" ]] && return 0
    local flags=()
    if [[ "$LD" == *"ld.lld" ]]; then
        _probe_ld_flag "-O2" && flags+=("-O2") || warn "LLD -O2 tidak didukung, skip"
        _probe_ld_flag "--sort-section=alignment" \
            && flags+=("--sort-section=alignment") \
            || warn "--sort-section=alignment tidak didukung, skip"
    fi
    _LLDFLAGS_CACHE="${flags[*]}"
    return 0
}

_build_kcflags() { echo "$_KCFLAGS_CACHE"; }
_build_kaflags() { echo "-march=armv8-a+crypto"; }

validate_kcflags() {
    local tmpdir; tmpdir=$(mktemp -d)
    echo "void dummy(void) {}" > "${tmpdir}/test.c"
    local -a flag_arr; IFS=' ' read -ra flag_arr <<< "$1"
    local stderr
    stderr=$("$CC_BASE" "${flag_arr[@]}" -c "${tmpdir}/test.c" -o "${tmpdir}/test.o" 2>&1 || true)
    rm -rf "$tmpdir"
    if echo "$stderr" | grep -qiE "unknown|unrecognized|invalid|not supported"; then
        err "KCFLAGS validation failed:"; echo "$stderr" >&2; return 1
    fi
    ok "KCFLAGS validated"
}

validate_kaflags() {
    local tmpdir; tmpdir=$(mktemp -d)
    printf '.section .text\n.globl _dummy\n_dummy:\n\tret\n' > "${tmpdir}/test.S"
    local -a flag_arr; IFS=' ' read -ra flag_arr <<< "$1"
    local stderr
    stderr=$("$AS" "${flag_arr[@]}" -c "${tmpdir}/test.S" -o "${tmpdir}/test.o" 2>&1 || true)
    rm -rf "$tmpdir"
    if echo "$stderr" | grep -qiE "unknown|unrecognized|invalid|not supported"; then
        err "KAFLAGS validation failed:"; echo "$stderr" >&2; return 1
    fi
    ok "KAFLAGS validated"
}

# ── dtc eksternal (Pixel way) ─────────────────────────────────────────────────

fetch_dtc() {
    # Prioritas: repo-local prebuilts/dtc/dtc, lalu cache di TOOLCHAIN_ROOT
    if [[ -z "$DTC_BIN" ]]; then
        if [[ -x "$SCRIPT_DIR/prebuilts/dtc/dtc" ]]; then
            DTC_BIN="$SCRIPT_DIR/prebuilts/dtc/dtc"
        else
            DTC_BIN="$TOOLCHAIN_ROOT/dtc/dtc"
        fi
    fi
    if [[ -x "$DTC_BIN" ]] && "$DTC_BIN" --version >/dev/null 2>&1; then
        ok "dtc    : $("$DTC_BIN" --version | head -1) ($DTC_BIN)"
        return 0
    fi
    if [[ "$OFFLINE" == "1" ]]; then
        warn "Offline: dtc eksternal tidak ada di $DTC_BIN"
        DTC_BIN=""
        return 1
    fi
    info "Download dtc prebuilt AOSP (cara Pixel sunfish)..."
    mkdir -p "$(dirname "$DTC_BIN")"
    local tmp="${DTC_BIN}.tmp"
    if curl -fsSL --connect-timeout 30 --retry 3 "$DTC_URL" | base64 -d > "$tmp" 2>/dev/null \
        && chmod +x "$tmp" && "$tmp" --version >/dev/null 2>&1; then
        mv "$tmp" "$DTC_BIN"
        ok "dtc    : $("$DTC_BIN" --version | head -1) (downloaded)"
        return 0
    fi
    rm -f "$tmp"
    warn "Gagal download dtc — fallback dtc internal (overlay dtbo bisa gagal)"
    DTC_BIN=""
    return 1
}

# ── Build args ────────────────────────────────────────────────────────────────

MAKE_ARGS=()
build_make_args() {
    MAKE_ARGS=(
        -j"$MAKE_PROCS" --output-sync=line
        O="$OUTDIR" ARCH="$ARCH"
        CC="$CC" LD="$LD" AR="$AR" AS="$AS" NM="$NM"
        OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" STRIP="$STRIP"
        CROSS_COMPILE="$CROSS_COMPILE"
        HOSTCC=gcc HOSTCXX=g++
        KBUILD_BUILD_USER="$BUILD_USER" KBUILD_BUILD_HOST="$BUILD_HOST"
        KBUILD_BUILD_VERSION=1
        KCFLAGS="$(_build_kcflags)"
        KAFLAGS="$(_build_kaflags)"
    )
    if [[ -n "${_LLDFLAGS_CACHE:-}" ]]; then
        MAKE_ARGS+=(LDFLAGS="$_LLDFLAGS_CACHE")
    fi
    if [[ -n "${DTC_EXT:-}" ]]; then
        MAKE_ARGS+=(DTC_EXT="$DTC_EXT")
    fi
}

# ── Build ─────────────────────────────────────────────────────────────────────

do_prepare() {
    local t0; t0=$(date +%s)
    if [[ "$INCREMENTAL" != "1" ]]; then
        [[ -d "$OUTDIR" ]] && { info "Hapus OUTDIR: $OUTDIR"; rm -rf "$OUTDIR"; }
        # mrproper WAJIB pakai O= — tanpa O= bisa menyapu .o di out-* lain di tree
        make "${MAKE_ARGS[@]}" mrproper >/dev/null 2>&1 || true
    fi
    make "${MAKE_ARGS[@]}" "$DEFCONFIG"

    make "${MAKE_ARGS[@]}" olddefconfig
    ok "Defconfig: $DEFCONFIG ($(_elapsed $t0))"
}

_pack_dtbo_manual() {
    local dtb_dir="$OUTDIR/arch/arm64/boot/dts/qcom"
    local out="$OUTDIR/arch/arm64/boot/dtbo.img"
    local mk="$SCRIPT_DIR/scripts/mkdtboimg.py"
    shopt -s nullglob; local files=("$dtb_dir"/*.dtbo); shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Tidak ada *.dtbo — dtbo.img tidak dibuat"
        return 1
    fi
    if [[ ! -f "$mk" ]]; then
        warn "scripts/mkdtboimg.py tidak ada — dtbo.img tidak dibuat"
        return 1
    fi
    python3 "$mk" create "$out" --page_size=4096 "${files[@]}" \
        && ok "dtbo.img (manual, ${#files[@]} overlay)"
}

do_build() {
    local t1; t1=$(date +%s)
    info "Build: Image.gz-dtb ..."
    make "${MAKE_ARGS[@]}" Image.gz-dtb
    ok "Image.gz-dtb ($(_elapsed $t1))"

    if grep -q '^CONFIG_BUILD_ARM64_DT_OVERLAY=y' "$OUTDIR/.config"; then
        info "Build: dtbo.img ..."
        if make "${MAKE_ARGS[@]}" dtbo.img; then
            ok "dtbo.img ($(_elapsed $t1))"
        else
            warn "target dtbo.img gagal — fallback packing manual"
            _pack_dtbo_manual || true
        fi
    else
        warn "CONFIG_BUILD_ARM64_DT_OVERLAY tidak aktif — dtbo.img dilewati"
    fi
}

copy_artifacts() {
    local image="$OUTDIR/arch/arm64/boot/Image.gz-dtb"
    local dtbo="$OUTDIR/arch/arm64/boot/dtbo.img"
    local krel="$OUTDIR/include/config/kernel.release"
    cp "$image" "$ARTIFACT_DIR/" && ok "Artifact: $ARTIFACT_DIR/Image.gz-dtb"
    if [[ -f "$dtbo" && -s "$dtbo" ]]; then
        cp "$dtbo" "$ARTIFACT_DIR/" && ok "Artifact: $ARTIFACT_DIR/dtbo.img"
    fi
    [[ -f "$krel" ]] && info "Kernel version: $(cat "$krel")"
    return 0
}

# ── Packaging (AnyKernel3) ────────────────────────────────────────────────────

prepare_anykernel() {
    if [[ ! -d "$ANYKERNEL_DIR" ]]; then
        git clone --depth=1 --branch "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$ANYKERNEL_DIR" 2>/dev/null \
        || git clone --depth=1 "$ANYKERNEL_REPO" "$ANYKERNEL_DIR" 2>/dev/null \
        || { warn "Gagal clone AnyKernel3"; return 1; }
        ok "AnyKernel3 cloned"
    else
        ( cd "$ANYKERNEL_DIR"
          git fetch --depth=1 origin "$ANYKERNEL_BRANCH" 2>/dev/null || true
          git reset --hard "origin/$ANYKERNEL_BRANCH" 2>/dev/null \
              || git reset --hard FETCH_HEAD 2>/dev/null \
              || warn "AnyKernel3 reset gagal — pakai state sekarang" )
    fi
    return 0
}

package_anykernel() {
    prepare_anykernel || return 1
    local image="$OUTDIR/arch/arm64/boot/Image.gz-dtb"
    local dtbo="$OUTDIR/arch/arm64/boot/dtbo.img"
    cp "$image" "$ANYKERNEL_DIR/"
    if [[ -f "$dtbo" && -s "$dtbo" ]]; then
        cp "$dtbo" "$ANYKERNEL_DIR/"
    else
        warn "dtbo.img kosong — tidak dimasukkan ke zip"
    fi
    ( cd "$ANYKERNEL_DIR"
      rm -f ./*.zip
      zip -r9 "$ZIPNAME" . --exclude ".git/*" --exclude "*.git*" --exclude "*.zip" ) \
        || { warn "zip gagal"; return 1; }
    mv "$ANYKERNEL_DIR/$ZIPNAME" "$SCRIPT_DIR/" || return 1
    local sz; sz=$(stat -c%s "$SCRIPT_DIR/$ZIPNAME")
    ok "Zip: $SCRIPT_DIR/$ZIPNAME ($(numfmt --to=iec-i --suffix=B "$sz" 2>/dev/null || echo "${sz}B"))"
    return 0
}

# ── Warnings ──────────────────────────────────────────────────────────────────

count_warnings() {
    local log="${1:-$LOGFILE}" n
    [[ -f "$log" ]] || { echo "0"; return 0; }
    n=$(grep -cP ':\d+:\d+: warning:' "$log" 2>/dev/null || true)
    echo "${n:-0}"
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
    return 0
}

summarize_warnings() {
    _extract_warnings
    local total; total=$(count_warnings "$LOGFILE")
    if [[ "$total" -eq 0 ]]; then
        ok "No warnings — clean build!"
        return 0
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
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    _validate_early
    check_deps
    ensure_make_compat
    find_toolchains
    fetch_dtc || true
    setup_env

    _populate_kcflags_cache
    _populate_ldflags_cache
    validate_kcflags "$(_build_kcflags)"
    validate_kaflags "$(_build_kaflags)"

    build_make_args

    do_prepare
    do_build
    copy_artifacts

    if [[ "$PACKAGE" == "1" ]]; then
        package_anykernel || warn "Packaging zip dilewati (hasil build kernel tetap OK)"
    fi

    summarize_warnings

    local krel="-"
    [[ -f "$OUTDIR/include/config/kernel.release" ]] && krel=$(cat "$OUTDIR/include/config/kernel.release")

    ok "============================================================"
    ok " BUILD SUCCESS — ${KERNEL_NAME}"
    ok " Device : POCO X3 NFC (surya) | SM7150"
    ok " Toolchain: GCC big.LITTLE (A76.A55) + $([[ "$LD" == *ld.lld ]] && echo LLD || echo binutils-ld)"
    ok " Kernel : ${krel}"
    ok " Output : build-artifacts/Image.gz-dtb$([[ -s "$OUTDIR/arch/arm64/boot/dtbo.img" ]] && echo ' + dtbo.img')"
    if [[ "$PACKAGE" == "1" && -f "$SCRIPT_DIR/$ZIPNAME" ]]; then
        ok " Zip    : ${ZIPNAME}"
    fi
    ok " Time   : $(_elapsed "$BUILD_START") (WIB)"
    ok "============================================================"
    return 0
}

main "$@"
