#!/usr/bin/env bash
set -euo pipefail

# build.sh — Kernel builder for POCO X3 NFC (surya)
# Kernel 4.14 (CAF, SM7150)
# Toolchain: persis Pixel 4a/sunfish (android-msm-sunfish-4.14-android13):
#   clang-r416183b + aarch64-linux-android-4.9 + arm-linux-androideabi-4.9
#   + dtc prebuilt AOSP via DTC_EXT (untuk overlay dtbo)
#
# Pemakaian:
#   bash build.sh                    # clean build + zip flashable
#   INCREMENTAL=1 bash build.sh      # incremental (tanpa hapus out/)
#   PACKAGE=0 bash build.sh          # build kernel saja (tanpa zip)
#   CCACHE=0 bash build.sh           # matikan ccache
#   CLANG_DIR=/path/ke/clang-rXXXXX bash build.sh   # override toolchain
#
# Hasil: build-artifacts/{log.txt,warnings.txt,Image.gz-dtb,dtbo.img} + <nama>.zip

export TZ="${TZ:-Asia/Jakarta}"

# ── Konfigurasi ───────────────────────────────────────────────────────────────

KERNEL_NAME="${KERNEL_NAME:-Farewell-EXT}"
DEFCONFIG="${DEFCONFIG:-surya_defconfig}"
OUTDIR="${OUTDIR:-out}"
ARCH="${ARCH:-arm64}"
BUILD_USER="${BUILD_USER:-Fannndi}"
BUILD_HOST="${BUILD_HOST:-$(hostname 2>/dev/null || echo linux)}"
MAKE_PROCS="${MAKE_PROCS:-$(nproc)}"
BUILD_START=$(date +%s)

INCREMENTAL="${INCREMENTAL:-0}"
PACKAGE="${PACKAGE:-1}"
WARN_DETAIL="${WARN_DETAIL:-1}"
OFFLINE="${OFFLINE:-0}"

# Toolchain — versi persis Pixel 4a/sunfish (android-msm-sunfish-4.14-android13):
#   clang-r416183b + aarch64-linux-android-4.9 + arm-linux-androideabi-4.9
TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-$HOME/toolchains}"
CLANG_VERSION="${CLANG_VERSION:-r416183b}"
CLANG_DIR="${CLANG_DIR:-}"
GCC64_DIR="${GCC64_DIR:-}"
GCC32_DIR="${GCC32_DIR:-}"
CCACHE="${CCACHE:-auto}"

# Sumber prebuilt (mirror AOSP prebuilts — LineageOS GitHub)
CLANG_REPO="${CLANG_REPO:-https://github.com/LineageOS/android_prebuilts_clang_kernel_linux-x86_clang-r416183b}"
GCC64_REPO="${GCC64_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9}"
GCC32_REPO="${GCC32_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_arm_arm-linux-androideabi-4.9}"

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
ZIPNAME="${KERNEL_NAME// /_}-$(date '+%d%m%Y-%H%M').zip"

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

info "Kernel Builder — POCO X3 NFC (surya) | 4.14 CAF | clang-$CLANG_VERSION + GCC 4.9 (Pixel sunfish)"
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

# ── Toolchain (Pixel sunfish: clang-r416183b + GCC binutils 4.9) ─────────────

_fetch_prebuilt() {
    local name="$1" repo="$2" dest="$3" bin="$4"
    if [[ -x "$dest/bin/$bin" ]]; then
        debug "Toolchain cached: $name"
        return 0
    fi
    if [[ "$OFFLINE" == "1" ]]; then
        warn "Offline: $name belum ada di cache ($dest)"
        return 1
    fi
    info "Download toolchain $name (git clone --depth=1)..."
    local tmp="${dest}.extracting"
    rm -rf "$tmp"
    if git clone --depth=1 --quiet "$repo" "$tmp" 2>/dev/null; then
        rm -rf "$dest"
        mv "$tmp" "$dest"
        ok "Toolchain siap: $name"
        return 0
    fi
    rm -rf "$tmp"
    warn "Gagal download: $repo"
    return 1
}

find_toolchains() {
    mkdir -p "$TOOLCHAIN_ROOT"

    # Clang (Pixel: $CLANG_VERSION)
    if [[ -z "$CLANG_DIR" ]]; then
        if [[ -x "$TOOLCHAIN_ROOT/clang-$CLANG_VERSION/bin/clang" ]]; then
            CLANG_DIR="$TOOLCHAIN_ROOT/clang-$CLANG_VERSION"
        elif _fetch_prebuilt "clang-$CLANG_VERSION" "$CLANG_REPO" "$TOOLCHAIN_ROOT/clang-$CLANG_VERSION" clang; then
            CLANG_DIR="$TOOLCHAIN_ROOT/clang-$CLANG_VERSION"
        else
            CLANG_DIR="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'clang-*' 2>/dev/null | sort -V | tail -1 || true)"
            if [[ -n "$CLANG_DIR" && -x "$CLANG_DIR/bin/clang" ]]; then
                warn "Fallback clang lokal: $CLANG_DIR"
            fi
        fi
    fi
    if [[ -z "$CLANG_DIR" || ! -x "$CLANG_DIR/bin/clang" ]]; then
        err "Clang tidak tersedia. Set CLANG_DIR=/path/ke/clang-rXXXXX"
        exit 1
    fi

    # GCC binutils aarch64 (Pixel: aarch64-linux-android-4.9)
    if [[ -z "$GCC64_DIR" ]]; then
        if [[ -x "$TOOLCHAIN_ROOT/aarch64-linux-android-4.9/bin/aarch64-linux-android-gcc" ]]; then
            GCC64_DIR="$TOOLCHAIN_ROOT/aarch64-linux-android-4.9"
        elif _fetch_prebuilt "aarch64-linux-android-4.9" "$GCC64_REPO" "$TOOLCHAIN_ROOT/aarch64-linux-android-4.9" aarch64-linux-android-gcc; then
            GCC64_DIR="$TOOLCHAIN_ROOT/aarch64-linux-android-4.9"
        else
            GCC64_DIR="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'aarch64-linux-android-*' 2>/dev/null | sort -V | tail -1 || true)"
        fi
    fi
    if [[ -z "$GCC64_DIR" || ! -x "$GCC64_DIR/bin/aarch64-linux-android-gcc" ]]; then
        err "GCC binutils aarch64 tidak tersedia. Set GCC64_DIR=/path/ke/aarch64-linux-android-4.9"
        exit 1
    fi

    # GCC binutils arm32 (Pixel: arm-linux-androideabi-4.9)
    if [[ -z "$GCC32_DIR" ]]; then
        if [[ -x "$TOOLCHAIN_ROOT/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-gcc" ]]; then
            GCC32_DIR="$TOOLCHAIN_ROOT/arm-linux-androideabi-4.9"
        elif _fetch_prebuilt "arm-linux-androideabi-4.9" "$GCC32_REPO" "$TOOLCHAIN_ROOT/arm-linux-androideabi-4.9" arm-linux-androideabi-gcc; then
            GCC32_DIR="$TOOLCHAIN_ROOT/arm-linux-androideabi-4.9"
        else
            GCC32_DIR="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'arm-linux-androideabi-*' 2>/dev/null | sort -V | tail -1 || true)"
        fi
    fi
    if [[ -n "$GCC32_DIR" && -x "$GCC32_DIR/bin/arm-linux-androideabi-gcc" ]]; then
        ok "GCC32 : $GCC32_DIR"
    else
        warn "GCC32 (arm-linux-androideabi-4.9) tidak ada — CROSS_COMPILE_ARM32 di-skip"
        GCC32_DIR=""
    fi

    ok "Clang : $("$CLANG_DIR/bin/clang" --version | head -1)"
    ok "GCC64 : $("$GCC64_DIR/bin/aarch64-linux-android-gcc" --version | head -1)"
    return 0
}

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

setup_env() {
    export PATH="$CLANG_DIR/bin:$GCC64_DIR/bin:$PATH"
    if [[ -n "$GCC32_DIR" ]]; then
        export PATH="$GCC32_DIR/bin:$PATH"
    fi
    export ARCH="$ARCH"
    export CLANG_TRIPLE=aarch64-linux-gnu-
    export CROSS_COMPILE=aarch64-linux-android-
    export CROSS_COMPILE_ARM32=arm-linux-androideabi-
    export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"
    export HOSTCC=gcc HOSTCXX=g++
    export KBUILD_BUILD_USER="$BUILD_USER"
    export KBUILD_BUILD_HOST="$BUILD_HOST"

    # dtc eksternal (Pixel way) — dipakai kernel lewat DTC_EXT
    if [[ -n "${DTC_BIN:-}" ]]; then
        export DTC_EXT="$DTC_BIN"
    fi

    # ccache (default: aktif bila tersedia)
    if [[ "$CCACHE" != "0" ]] && command -v ccache >/dev/null 2>&1; then
        export CC="ccache clang"
        export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
        mkdir -p "$CCACHE_DIR"
        ok "ccache : aktif ($CCACHE_DIR)"
    else
        export CC="clang"
    fi
    ok "Environment siap (Pixel-style: clang + binutils GCC 4.9)"
}

MAKE_ARGS=()
build_make_args() {
    MAKE_ARGS=(
        -j"$MAKE_PROCS" --output-sync=line
        O="$OUTDIR" ARCH="$ARCH"
        CC="$CC" CLANG_TRIPLE=aarch64-linux-gnu-
        CROSS_COMPILE=aarch64-linux-android-
        CROSS_COMPILE_ARM32=arm-linux-androideabi-
        HOSTCC=gcc HOSTCXX=g++
        KBUILD_BUILD_USER="$BUILD_USER" KBUILD_BUILD_HOST="$BUILD_HOST"
        KBUILD_BUILD_VERSION=1
    )
    if [[ -n "${DTC_EXT:-}" ]]; then
        MAKE_ARGS+=(DTC_EXT="$DTC_EXT")
    fi
}

# ── Build ─────────────────────────────────────────────────────────────────────

do_prepare() {
    local t0; t0=$(date +%s)
    if [[ "$INCREMENTAL" != "1" ]]; then
        [[ -d "$OUTDIR" ]] && { info "Hapus OUTDIR: $OUTDIR"; rm -rf "$OUTDIR"; }
        make mrproper >/dev/null 2>&1 || true
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
    local log="${1:-$LOGFILE}"
    [[ -f "$log" ]] || { echo "0"; return 0; }
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
    ok " Toolchain: clang-$CLANG_VERSION + GCC 4.9 (Pixel sunfish style)"
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
