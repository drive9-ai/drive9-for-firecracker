#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUTS_DIR="${PROJECT_ROOT}/outputs"

LINUX_VERSION="${LINUX_VERSION:-5.10.234}"
LINUX_TARBALL="linux-${LINUX_VERSION}.tar.xz"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/${LINUX_TARBALL}"
FC_CONFIG_URL="https://raw.githubusercontent.com/firecracker-microvm/firecracker/main/resources/guest_configs/microvm-kernel-ci-x86_64-5.10.config"

mkdir -p "${OUTPUTS_DIR}"

# Skip if already built
if [[ -f "${OUTPUTS_DIR}/vmlinux-custom" ]]; then
    echo "Kernel already built: ${OUTPUTS_DIR}/vmlinux-custom"
    echo "Run 'make clean' to rebuild."
    exit 0
fi

# Download kernel source
echo "Downloading Linux ${LINUX_VERSION}..."
if [[ ! -f "${OUTPUTS_DIR}/${LINUX_TARBALL}" ]]; then
    curl -L -o "${OUTPUTS_DIR}/${LINUX_TARBALL}" "${LINUX_URL}"
fi

LINUX_SRC="${OUTPUTS_DIR}/linux-${LINUX_VERSION}"

if [[ -d "${LINUX_SRC}" ]]; then
    echo "Kernel source already extracted: ${LINUX_SRC}"
else
    echo "Extracting kernel source..."
    tar -C "${OUTPUTS_DIR}" -xf "${OUTPUTS_DIR}/${LINUX_TARBALL}"
fi

cd "${LINUX_SRC}"

# Download Firecracker guest config
echo "Downloading Firecracker kernel config..."
curl -L -o .config "${FC_CONFIG_URL}"

# Apply FUSE patch
echo "Applying FUSE configuration..."
# Enable FUSE as built-in
cat >> .config << 'KCONFIG'
CONFIG_FUSE_FS=y
KCONFIG

# Olddefconfig to resolve any conflicts
make olddefconfig

# Verify FUSE is enabled
grep "^CONFIG_FUSE_FS=y" .config >/dev/null || {
    echo "ERROR: CONFIG_FUSE_FS not enabled"
    exit 1
}

# Fix GCC C23 compatibility (for GCC 15+)
echo "Patching for GCC C23 compatibility..."
# Replace -std=gnu89 with -std=gnu11 in Makefiles (more reliable than KBUILD_CFLAGS matching)
find . -name Makefile -exec sed -i 's/-std=gnu89/-std=gnu11/g' {} + 2>/dev/null || true

# Build kernel
echo "Building kernel (this may take 10-30 minutes)..."
make -j"$(nproc)" vmlinux

# Copy output
cp "${LINUX_SRC}/vmlinux" "${OUTPUTS_DIR}/vmlinux-custom"

echo ""
echo "Kernel build complete: ${OUTPUTS_DIR}/vmlinux-custom"
file "${OUTPUTS_DIR}/vmlinux-custom"
