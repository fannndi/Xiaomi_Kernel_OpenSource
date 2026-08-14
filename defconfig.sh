#!/bin/bash
set -euo pipefail

# Pindah ke root kernel (folder tempat Makefile)
if [[ ! -f Makefile ]]; then
  ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  cd "$ROOT_DIR" || { echo "❌ Tidak bisa masuk ke $ROOT_DIR"; exit 1; }
fi

# Validasi Makefile
if [[ ! -f Makefile ]]; then
  echo "❌ Makefile tidak ditemukan di $(pwd). Pastikan script dijalankan di root kernel."
  exit 1
fi

# Variabel utama
OUT_DIR="out"
DEFCONFIG="arch/arm64/configs/surya_defconfig"
CONFIG_FILE="$OUT_DIR/.config"
BACKUP="${DEFCONFIG}.bak.$(date +%s)"

# Warna
RED="\033[0;31m"
GRN="\033[0;32m"
YEL="\033[1;33m"
NC="\033[0m"

# Validasi defconfig
[[ ! -f "$DEFCONFIG" ]] && {
  echo -e "${RED}❌ Defconfig tidak ditemukan: $DEFCONFIG${NC}"
  exit 1
}

# Bersihkan folder out
echo -e "${YEL}🧹 Menghapus folder $OUT_DIR/...${NC}"
rm -rf "$OUT_DIR"

# Generate .config
echo -e "${YEL}📦 Membuat ulang .config dari $DEFCONFIG...${NC}"
make O="$OUT_DIR" ARCH=arm64 surya_defconfig

# Olddefconfig
echo -e "${YEL}🔄 Menjalankan make olddefconfig...${NC}"
make O="$OUT_DIR" ARCH=arm64 olddefconfig

# Backup lama
echo -e "${YEL}🗑️ Menghapus backup lama...${NC}"
rm -f "${DEFCONFIG}".bak.*

# Backup baru
echo -e "${YEL}🛡️ Backup defconfig lama ke: $BACKUP${NC}"
cp "$DEFCONFIG" "$BACKUP"

# Timpa defconfig
cp "$CONFIG_FILE" "$DEFCONFIG"
echo -e "${GRN}✅ Defconfig diperbarui di: $DEFCONFIG${NC}"

# Tambahkan out/ ke .gitignore
if [[ ! -f .gitignore ]] || ! grep -qxF "$OUT_DIR/" .gitignore; then
  echo "$OUT_DIR/" >> .gitignore
  echo -e "${GRN}📌 Menambahkan $OUT_DIR/ ke .gitignore${NC}"
fi

# Bersihkan out
rm -rf "$OUT_DIR"
echo -e "${YEL}🧽 Folder $OUT_DIR dibersihkan.${NC}"

echo -e "${GRN}🎉 Selesai! Defconfig berhasil diregenerasi dan dibackup.${NC}"