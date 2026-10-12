#!/usr/bin/env bash
set -euo pipefail

# build.sh — Dispatcher varian build kernel (POCO X3 NFC / surya)
#
#   bash build.sh           # default: GCC big.LITTLE
#   bash build.sh gcc       # GCC big.LITTLE (EVA GCC 17 + LLD)   → build-gcc.sh
#   bash build.sh clang     # Clang + LTO (Pixel-style)           → build-clang.sh
#
# Env var diteruskan ke script varian, contoh:
#   INCREMENTAL=1 bash build.sh gcc
#   LTO=thin      bash build.sh clang
#   PACKAGE=0     bash build.sh clang

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARIANT="${1:-gcc}"

case "$VARIANT" in
    gcc)
        exec bash "$SCRIPT_DIR/build-gcc.sh" "${@:2}"
        ;;
    clang)
        exec bash "$SCRIPT_DIR/build-clang.sh" "${@:2}"
        ;;
    -h|--help|help)
        sed -n '4,15p' "$SCRIPT_DIR/build.sh"
        ;;
    *)
        echo "Varian tidak dikenal: $VARIANT" >&2
        echo "Pakai: bash build.sh [gcc|clang]" >&2
        exit 1
        ;;
esac
