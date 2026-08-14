# LLM Notes — Kernel Surya

## Identitas Device

- **Device**: Xiaomi POCO X3 NFC / POCO X3 (codename **surya**)
- **SoC**: Qualcomm Snapdragon 732G (**SM7150-AB**), msm-id 355/365, codename kernel `sdmmagpie`
- **Kernel**: Linux 4.14.180 (CAF MSM-4.14), base tag `LA.UM.9.1.r1-06700-SMxxx0.0` (Android 11)
- **Defconfig**: `arch/arm64/configs/surya_defconfig` (`LOCALVERSION="-perf"`)
- **Branch**: `tune`
- **SoC sama dgn**: sweet (Redmi Note 10 Pro), courbet, k6a — patch dari mereka umumnya relevan.
- **Hardware beda dgn sweet**: surya LCD + fingerprint sidemount + kamera IMX682 + touch Novatek. Jangan port panel AMOLED/FOD/camera sensor device lain.

## Konteks Singkat

- Remote relevan: `mcode` (sweet-r-oss, sweet_k6a-r-oss), `origin`, `rebase` (branch).
- Base CAF: `a11fbb33`. Awal tune: `ccdbd81e5f76f`.
- Build: `build.sh` (default `surya_defconfig`), toolchain `toolchains/eva-gcc-arm64-09082026`.
- Banyak port sudah masuk (sweet-r/k6a/courbet + 57 commit cherry-pick dari `rebase`). Referensi patch: `/home/fannndi/Downloads/{sweet-r,courbet,surya-q}-oss.patch`.
- Charger surya pakai **BQ2597x** (bukan smb1390).
- Jangan commit tanpa persetujuan user.

## Aturan Upstream

Kernel ini berbasis **CLO (CodeLinaro/CAF) + OEM driver (Xiaomi)** dan akan di-merge dengan:
- **Google Android Security Bulletin (ASB)** — patch keamanan AOSP android-4.14 / common kernel.
- **CodeLinaro CAF Tag** — update dari `https://git.codelinaro.org/clo/la/kernel/msm-4.14.git` (remote `caf`).

Cara merge upstream:
1. **Cari source patch**:
   - ASB: repo `android-common` / `android-4.14` (AOSP kernel common). Cek via remote `caf` (branch `aosp-new/...` / `upstream-linux-4.14.y`) atau fetch upstream `https://android.googlesource.com/kernel/common`.
   - CAF: remote `caf` branch `LA.UM.9.1*` / `msm-4.14*` (tag `LA.UM.9.1.r1-06700-*` dst).
2. **Hati-hati konflik dengan modifikasi local** (banyak file sudah di-port dari sweet/k6a/courbet). Merge kecil & per-file lebih aman; resolve konflik manual dgn preferensi: upstream fix (ASB/CAF) utk bug/security, pertahankan tuning OEM/local kecuali upstream memang lebih baru.
3. **Jangan menimpa** tuning khusus surya (charging BQ2597x, sched MIUI boost, dtc/techpack) tanpa alasan jelas.
4. Setelah merge, verifikasi: `git status` bersih, konflik selesai, build config utuh (`surya_defconfig`), tidak ada referensi symbol yang hilang.

- User ke depan: fix kecil + merge upstream (ASB, CAF tag). Untuk merge CAF/ASB, cek remote `caf` (kernel/msm-4.14) & bandingkan dengan branch `rebase`/`mcode` bila perlu.
