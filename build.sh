#!/bin/bash

# Kernel build script for mtkpapa/kernel_xiaomi_sm8250_mod @ 4e043d8
# Target: KernelSU-Next v3.3.0 + SUSFS v2.2.0 (NON-GKI 4.19)
#
# This keeps the original MIUI/AnyKernel3 build flow and replaces the old
# KSU/SUSFS integration with:
#   - pershoot/KernelSU-Next dev-susfs, tag v3.3.0
#   - JackA1ltman's SUSFS v2.2.0 patch for kernel 4.19
#   - SUSFS v2.2 inline-hook patch set
#
# Build:
#   bash build.sh psyche ksu
#
# NOTE:
# SUSFS/KernelSU integration is kernel-source dependent. The script performs
# a dry-run before applying the 4.19 SUSFS patch and aborts on a patch conflict.

set -euo pipefail

TARGET_DEVICE="${1:-}"

if [ -z "$TARGET_DEVICE" ]; then
    echo "Error: No argument provided, please specify a target device."
    echo "Build without KernelSU:"
    echo "    bash build.sh psyche"
    echo "Build with KernelSU-Next 3.3.0 + SUSFS 2.2.0:"
    echo "    bash build.sh psyche ksu"
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[ERROR] clang does not exist, please check your environment."
    exit 1
fi

for cmd in git curl patch zip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Required command '$cmd' does not exist."
        exit 1
    fi
done

# Enable ccache for speed up compiling
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache_mikernel}"
export PATH="/usr/lib/ccache:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"

MAKE_ARGS=(
    ARCH=arm64
    SUBARCH=arm64
    O=out
    "CC=ccache clang"
    "CXX=ccache clang++"
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    CLANG_TRIPLE=aarch64-linux-gnu-
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    "HOSTCC=ccache clang"
    "HOSTCXX=ccache clang++"
    LD=ld.lld
    LLVM=1
    LLVM_IAS=0
)

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Available defconfigs:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi

clang --version

KSU_ZIP_STR=NoKernelSU
if [ "${2:-}" = "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=KernelSU-Next-v3.3.0-SUSFS-v2.2.0
else
    KSU_ENABLE=0
fi

echo "TARGET_DEVICE: $TARGET_DEVICE"
echo "KSU_ENABLE: $KSU_ENABLE"

# ---------------------------------------------------------------------------
# KernelSU-Next + SUSFS setup
# ---------------------------------------------------------------------------

KSU_SETUP_URL="https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh"
KSU_REF="v3.3.0"

SUSFS_PATCH_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/Patch/susfs_patch_to_4.19.patch"
SUSFS_INLINE_URL="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/mainline/Patches/susfs_inline_hook_patches.sh"

setup_ksu_susfs() {
    echo "================================================================"
    echo "[+] Setting up KernelSU-Next v3.3.0 (pershoot dev-susfs)"
    echo "================================================================"

    # The setup script will create/update KernelSU-Next and the drivers/kernelsu
    # integration. Remove only a previous KernelSU-Next checkout; do not touch
    # the rest of the kernel source.
    rm -rf KernelSU-Next

    curl -fL --retry 3 --retry-delay 2 "$KSU_SETUP_URL" \
        | bash -s "$KSU_REF"

    if [ ! -f "KernelSU-Next/kernel/Kconfig" ]; then
        echo "[ERROR] KernelSU-Next kernel source was not installed."
        exit 1
    fi

    echo "[+] Verifying KernelSU-Next version..."
    if ! grep -q 'menu "KernelSU - SUSFS"' KernelSU-Next/kernel/Kconfig; then
        echo "[ERROR] The selected KernelSU-Next source does not contain its SUSFS Kconfig."
        echo "[ERROR] Refusing to continue with a mismatched KSU tree."
        exit 1
    fi

    echo "[+] Downloading SUSFS v2.2.0 kernel patch..."
    mkdir -p .build-patches
    curl -fL --retry 3 --retry-delay 2 \
        "$SUSFS_PATCH_URL" \
        -o .build-patches/susfs_patch_to_4.19.patch

    if ! grep -q '#define SUSFS_VERSION "v2.2.0"' .build-patches/susfs_patch_to_4.19.patch; then
        echo "[ERROR] Downloaded SUSFS patch is not v2.2.0."
        exit 1
    fi

    echo "[+] SUSFS v2.2.0 patch detected."

    # Make sure we are patching the intended 4.19 source.
    KERNEL_VERSION="$(head -n 3 Makefile | grep -E '^(VERSION|PATCHLEVEL)' | awk '{print $3}' | paste -sd '.')"
    echo "[+] Kernel version detected: ${KERNEL_VERSION}"

    if [[ "${KERNEL_VERSION}" != 4.19* ]]; then
        echo "[ERROR] This build script is specifically for the 4.19 SUSFS patch."
        exit 1
    fi

    echo "[+] Checking SUSFS 4.19 patch with --dry-run..."
    if ! patch -p1 --dry-run --forward < .build-patches/susfs_patch_to_4.19.patch; then
        echo "[ERROR] SUSFS v2.2.0 patch does not apply cleanly to this source."
        echo "[ERROR] No SUSFS patch was applied by this script."
        exit 1
    fi

    echo "[+] Applying SUSFS v2.2.0..."
    patch -p1 --forward < .build-patches/susfs_patch_to_4.19.patch

    echo "[+] Downloading SUSFS v2.2 inline-hook patch script..."
    curl -fL --retry 3 --retry-delay 2 \
        "$SUSFS_INLINE_URL" \
        -o .build-patches/susfs_inline_hook_patches.sh

    chmod +x .build-patches/susfs_inline_hook_patches.sh

    echo "[+] Applying SUSFS v2.2 inline hooks..."
    bash .build-patches/susfs_inline_hook_patches.sh

    if ! grep -q '#define SUSFS_VERSION "v2.2.0"' include/linux/susfs.h; then
        echo "[ERROR] SUSFS v2.2.0 was not found in include/linux/susfs.h."
        exit 1
    fi

    echo "[+] KernelSU-Next + SUSFS source integration completed."
}

# ---------------------------------------------------------------------------
# Cleaning / AnyKernel3
# ---------------------------------------------------------------------------

echo "Cleaning..."
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/liyafe1997/AnyKernel3)"
git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel

# Add date to local version
local_version_str="-perf"
local_version_date_str="-IlyafeKernel-$(date +%Y%m%d)"

# Keep original output location used by the 20250921 script.
KOUT_PATH="/mnt/d/users/juan/kernels/${TARGET_DEVICE}/"
mkdir -p "$KOUT_PATH"

if [ "$KSU_ENABLE" -eq 1 ]; then
    setup_ksu_susfs
fi

# ---------------------------------------------------------------------------
# Building for MIUI
# ---------------------------------------------------------------------------

build_miui() {
    echo "Clearning [out/] and build for MIUI....."
    rm -rf out/

    make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"

    sed -i "s/${local_version_str}/${local_version_date_str}/g" out/.config

    if [ "$KSU_ENABLE" -eq 1 ]; then
        echo "[+] Enabling KernelSU-Next + SUSFS v2.2.0 kernel configs..."

        # The pershoot dev-susfs v3.3.0 Kconfig already provides SUSFS
        # and its feature defaults. Explicitly enable the main symbols and
        # every feature that exists in this Kconfig.
        scripts/config --file out/.config \
            -e KSU \
            -e KSU_SUSFS

        for cfg in \
            KSU_SUSFS_SUS_PATH \
            KSU_SUSFS_SUS_MOUNT \
            KSU_SUSFS_SUS_KSTAT \
            KSU_SUSFS_SPOOF_UNAME \
            KSU_SUSFS_ENABLE_LOG \
            KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
            KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            KSU_SUSFS_OPEN_REDIRECT \
            KSU_SUSFS_SUS_MAP
        do
            if grep -qE "^[[:space:]]*config[[:space:]]+${cfg}[[:space:]]*$" \
                KernelSU-Next/kernel/Kconfig; then
                scripts/config --file out/.config -e "$cfg"
            fi
        done
    else
        scripts/config --file out/.config -d KSU
        scripts/config --file out/.config -d KSU_SUSFS
    fi

    scripts/config --file out/.config \
        --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
        -e PERF_CRITICAL_RT_TASK \
        -e SF_BINDER \
        -e OVERLAY_FS \
        -d DEBUG_FS \
        -e MIGT \
        -e MIGT_ENERGY_MODEL \
        -e MIHW \
        -e PACKAGE_RUNTIME_INFO \
        -e BINDER_OPT \
        -e KPERFEVENTS \
        -e MILLET \
        -e PERF_HUMANTASK \
        -d LOCALVERSION_AUTO \
        -e SF_BINDER \
        -e XIAOMI_MIUI \
        -d MI_MEMORY_SYSFS \
        -e TASK_DELAY_ACCT \
        -e MIUI_ZRAM_MEMORY_TRACKING \
        -d CONFIG_MODULE_SIG_SHA512 \
        -d CONFIG_MODULE_SIG_HASH \
        -e MI_FRAGMENTION \
        -e PERF_HELPER \
        -e BOOTUP_RECLAIM \
        -e MI_RECLAIM \
        -e RTMM

    echo "[+] Final KSU/SUSFS config:"
    grep -E '^CONFIG_KSU(=|_)|^CONFIG_KSU_SUSFS' out/.config || true

    make "${MAKE_ARGS[@]}" -j"$(nproc)"

    if [ -f "out/arch/arm64/boot/Image" ]; then
        echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
    else
        echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
        exit 1
    fi

    echo "Generating [out/arch/arm64/boot/dtb]......"
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb

    rm -rf anykernel/kernels/
    mkdir -p anykernel/kernels/

    cp out/arch/arm64/boot/Image anykernel/kernels/
    cp out/arch/arm64/boot/dtb anykernel/kernels/

    echo "Build for MIUI finished."

    cd anykernel

    ZIP_FILENAME="IlyafeKernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S').zip"

    zip -r9 "$ZIP_FILENAME" ./* -x .git .gitignore out/ ./*.zip

    mv "$ZIP_FILENAME" "$KOUT_PATH"

    cd ..

    echo "Flashable ZIP:"
    echo "  ${KOUT_PATH}${ZIP_FILENAME}"
}

# ------------- End of Building for MIUI -------------

build_miui

echo "Done."

rm -rf out/
rm -rf KernelSU-Next/
rm -rf anykernel/
rm -rf .build-patches/
