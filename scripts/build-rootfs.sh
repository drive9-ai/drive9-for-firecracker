#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUTS_DIR="${PROJECT_ROOT}/outputs"
# drive9 download URL (auto-download, no env var needed)
DRIVE9_URL="https://drive9.ai/releases/drive9-linux-amd64"
DRIVE9_TMP="${OUTPUTS_DIR}/tmp/drive9-download"

ALPINE_VERSION="3.19.7"
ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VERSION}-x86_64.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/${ALPINE_TARBALL}"

ROOTFS_SIZE="${ROOTFS_SIZE:-2048}"  # MB
ROOTFS_IMG="${OUTPUTS_DIR}/rootfs.ext4"
MOUNT_POINT="${OUTPUTS_DIR}/tmp/rootfs-mount"

mkdir -p "${OUTPUTS_DIR}/tmp"

# Skip if already built
if [[ -f "${ROOTFS_IMG}" ]]; then
    echo "Rootfs already built: ${ROOTFS_IMG}"
    echo "Run 'make clean' to rebuild."
    exit 0
fi

# Download drive9 binary (static, ~14MB)
if [[ ! -f "${DRIVE9_TMP}" ]]; then
    echo "Downloading drive9 binary from ${DRIVE9_URL}..."
    curl -fsSL -o "${DRIVE9_TMP}" "${DRIVE9_URL}"
    chmod +x "${DRIVE9_TMP}"
    echo "drive9 downloaded: $("${DRIVE9_TMP}" --version 2>/dev/null || echo 'version unknown')"
else
    echo "Using cached drive9 binary: ${DRIVE9_TMP}"
fi

# Download Alpine minirootfs
echo "Downloading Alpine ${ALPINE_VERSION} minirootfs..."
if [[ ! -f "${OUTPUTS_DIR}/${ALPINE_TARBALL}" ]]; then
    curl -L -o "${OUTPUTS_DIR}/${ALPINE_TARBALL}" "${ALPINE_URL}"
fi

# Create ext4 image
echo "Creating ${ROOTFS_SIZE}MB ext4 rootfs image..."
dd if=/dev/zero of="${ROOTFS_IMG}" bs=1M count="${ROOTFS_SIZE}"
mkfs.ext4 "${ROOTFS_IMG}"

# Mount and extract
echo "Mounting rootfs..."
mkdir -p "${MOUNT_POINT}"
sudo mount -o loop "${ROOTFS_IMG}" "${MOUNT_POINT}"

# Extract Alpine base
echo "Extracting Alpine minirootfs..."
sudo tar -C "${MOUNT_POINT}" -xzf "${OUTPUTS_DIR}/${ALPINE_TARBALL}"

# Setup DNS for chroot
echo "Setting up chroot environment..."
sudo cp /etc/resolv.conf "${MOUNT_POINT}/etc/resolv.conf"

# Install packages inside chroot
echo "Installing packages (fuse3, openssh, openrc, util-linux, kmod)..."
sudo chroot "${MOUNT_POINT}" /bin/sh << 'CHROOT_EOF'
apk update
apk add --no-cache fuse3 fuse3-libs openssh-server openrc util-linux kmod ca-certificates curl bash

# Enable OpenRC services
ln -s /etc/init.d/crond /etc/runlevels/default/crond 2>/dev/null || true

# Enable serial console auto-login
mkdir -p /etc/runlevels/default
ln -s /etc/init.d/agetty /etc/runlevels/default/agetty.ttyS0 2>/dev/null || true

cat > /etc/inittab << 'INIT'
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100
::shutdown:/sbin/openrc shutdown
INIT

# Configure SSH
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
echo 'root:root' | chpasswd

# Configure network (static IP)
cat > /etc/local.d/network.start << 'NET'
#!/bin/sh
ip addr add 172.20.0.2/30 dev eth0
ip link set eth0 up
ip route add default via 172.20.0.1
NET
chmod +x /etc/local.d/network.start

# Configure drive9 auto-mount
# API key is passed via kernel cmdline: drive9_api_key=...
# This script parses /proc/cmdline to extract it
cat > /etc/local.d/drive9-mount.start << 'DRIVE9'
#!/bin/sh

# Parse drive9_api_key from kernel cmdline
API_KEY=$(cat /proc/cmdline | tr ' ' '\n' | grep '^drive9_api_key=' | cut -d= -f2-)

if [ -z "$API_KEY" ]; then
    echo "drive9: DRIVE9_API_KEY not found in kernel cmdline, skipping mount" > /dev/ttyS0
    exit 0
fi

export HOME=/root
mkdir -p /mnt/drive9

# Create drive9 context
drive9 ctx add --api-key "$API_KEY" --name default >/dev/null 2>&1

# Start drive9 mount in background
nohup drive9 mount -sync-mode=strict /mnt/drive9 >/dev/null 2>&1 &

echo "drive9: mount initiated" > /dev/ttyS0
DRIVE9
chmod +x /etc/local.d/drive9-mount.start

# Enable services
ln -s /etc/init.d/local /etc/runlevels/default/local 2>/dev/null || true
ln -s /etc/init.d/sshd /etc/runlevels/default/sshd 2>/dev/null || true

# Ensure local.d scripts are executable
chmod +x /etc/local.d/*.start 2>/dev/null || true
CHROOT_EOF

# Copy drive9 binary
echo "Installing drive9 binary..."
sudo cp "${DRIVE9_TMP}" "${MOUNT_POINT}/usr/local/bin/drive9"
sudo chmod +x "${MOUNT_POINT}/usr/local/bin/drive9"

# Unmount
echo "Unmounting rootfs..."
sudo umount "${MOUNT_POINT}"

echo ""
echo "Rootfs build complete: ${ROOTFS_IMG}"
ls -lh "${ROOTFS_IMG}"
