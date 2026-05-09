#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUTS_DIR="${PROJECT_ROOT}/outputs"

FC_RELEASE="${FC_RELEASE:-v1.15.1}"
FC_TARBALL="firecracker-${FC_RELEASE}-x86_64.tgz"
FC_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_RELEASE}/${FC_TARBALL}"
FC_BIN="${OUTPUTS_DIR}/release-${FC_RELEASE}-x86_64/firecracker-${FC_RELEASE}-x86_64"
FC_SOCK="/tmp/firecracker-drive9.sock"

TAP_DEV="${TAP_DEV:-fc-tap0}"
VMLINUX="${OUTPUTS_DIR}/vmlinux-custom"
ROOTFS="${OUTPUTS_DIR}/rootfs.ext4"

# Validate build artifacts exist
if [[ ! -f "${VMLINUX}" ]]; then
    echo "ERROR: Kernel not found at ${VMLINUX}"
    echo "Run: make kernel"
    exit 1
fi
if [[ ! -f "${ROOTFS}" ]]; then
    echo "ERROR: Rootfs not found at ${ROOTFS}"
    echo "Run: make rootfs"
    exit 1
fi

# Download Firecracker if needed
if [[ ! -f "${FC_BIN}" ]]; then
    echo "Downloading Firecracker ${FC_RELEASE}..."
    mkdir -p "${OUTPUTS_DIR}"
    curl -L -o "${OUTPUTS_DIR}/${FC_TARBALL}" "${FC_URL}"
    tar -C "${OUTPUTS_DIR}" -xzf "${OUTPUTS_DIR}/${FC_TARBALL}"
fi

# Prepare API key for kernel cmdline
API_KEY_ARG=""
if [[ -n "${DRIVE9_API_KEY:-}" ]]; then
    # Sanitize: remove newlines/spaces, encode minimally for cmdline
    API_KEY_CLEAN="${DRIVE9_API_KEY//[$'\n\r\t ']/}"
    API_KEY_ARG=" drive9_api_key=${API_KEY_CLEAN}"
    echo "API key will be passed via kernel cmdline"
else
    echo "WARNING: DRIVE9_API_KEY not set, drive9 will not auto-mount"
fi

# Clean up old Firecracker
pkill -f "firecracker-${FC_RELEASE}" 2>/dev/null || true
rm -f "${FC_SOCK}"

# Start Firecracker
echo "Starting Firecracker..."
"${FC_BIN}" --api-sock "${FC_SOCK}" > "${OUTPUTS_DIR}/firecracker.log" 2>&1 &
FC_PID=$!
sleep 1

# Configure VM
curl -s --unix-socket "${FC_SOCK}" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d '{"vcpu_count": 2, "mem_size_mib": 1024, "smt": false}'

curl -s --unix-socket "${FC_SOCK}" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{\"kernel_image_path\": \"${VMLINUX}\", \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw${API_KEY_ARG}\"}"

curl -s --unix-socket "${FC_SOCK}" -X PUT "http://localhost/drives/rootfs" \
    -H "Content-Type: application/json" \
    -d "{\"drive_id\": \"rootfs\", \"path_on_host\": \"${ROOTFS}\", \"is_root_device\": true, \"is_read_only\": false}"

curl -s --unix-socket "${FC_SOCK}" -X PUT "http://localhost/network-interfaces/eth0" \
    -H "Content-Type: application/json" \
    -d "{\"iface_id\": \"eth0\", \"guest_mac\": \"AA:FC:00:00:00:01\", \"host_dev_name\": \"${TAP_DEV}\"}"

# Start instance
curl -s --unix-socket "${FC_SOCK}" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type": "InstanceStart"}'

echo ""
echo "Firecracker started. PID=${FC_PID}"
echo "Serial log: tail -f ${OUTPUTS_DIR}/firecracker.log"
echo "SSH: sshpass -p root ssh -o StrictHostKeyChecking=no root@172.20.0.2"
echo ""
echo "Press Ctrl+C to stop or run: pkill -f firecracker-${FC_RELEASE}"

# Stream serial log (or just wait if NO_TAIL is set)
if [[ -z "${NO_TAIL:-}" ]]; then
    tail -f "${OUTPUTS_DIR}/firecracker.log" 2>/dev/null || wait "${FC_PID}"
else
    wait "${FC_PID}"
fi
