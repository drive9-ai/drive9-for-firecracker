#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUTS_DIR="${PROJECT_ROOT}/outputs"
FC_RELEASE="${FC_RELEASE:-v1.15.1}"
FC_BIN_PATTERN="firecracker-${FC_RELEASE}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check prerequisites
if [[ -z "${DRIVE9_API_KEY:-}" ]]; then
    log_error "DRIVE9_API_KEY environment variable is not set"
    echo "Usage: DRIVE9_API_KEY=dat9_xxx ./scripts/run-drive9-demo.sh"
    exit 1
fi

# Check for required tools
for cmd in curl jq sudo; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required tool not found: $cmd"
        exit 1
    fi
done

# Step 1: Build kernel
if [[ ! -f "${OUTPUTS_DIR}/vmlinux-custom" ]]; then
    log_info "Step 1/4: Building kernel..."
    make -C "${PROJECT_ROOT}" kernel
else
    log_info "Step 1/4: Kernel already built, skipping"
fi

# Step 2: Build rootfs
if [[ ! -f "${OUTPUTS_DIR}/rootfs.ext4" ]]; then
    log_info "Step 2/4: Building rootfs..."
    make -C "${PROJECT_ROOT}" rootfs
else
    log_info "Step 2/4: Rootfs already built, skipping"
fi

# Step 3: Setup network
log_info "Step 3/4: Setting up host network..."
make -C "${PROJECT_ROOT}" network

# Step 4: Start Firecracker in background and verify drive9 mount
log_info "Step 4/4: Starting Firecracker microVM..."
log_info "API key will be passed via kernel cmdline"

# Start Firecracker in background (no tail -f, so it doesn't interfere with our terminal)
NO_TAIL=1 bash "${SCRIPT_DIR}/start-firecracker.sh" > /tmp/fc-start.log 2>&1 &
START_PID=$!

# Give Firecracker time to boot
log_info "Waiting for VM to boot (~10s)..."
sleep 12

# Check if VM is running
if ! pgrep -f "$FC_BIN_PATTERN" >/dev/null; then
    log_error "Firecracker failed to start. Check ${OUTPUTS_DIR}/firecracker.log"
    exit 1
fi

# Extract boot time and mount status from serial log
log_info "Checking serial log for drive9 mount status..."

# Wait for drive9 mount marker (up to 30 seconds)
MOUNT_READY=0
for i in $(seq 1 30); do
    if grep -q "drive9: mount initiated" "${OUTPUTS_DIR}/firecracker.log" 2>/dev/null; then
        MOUNT_READY=1
        break
    fi
    sleep 1
done

if [[ "$MOUNT_READY" -eq 1 ]]; then
    log_info "drive9 mount initiated successfully"
else
    log_warn "drive9 mount marker not found in serial log"
    log_warn "This may be normal if the mount takes longer. Check log manually."
fi

# Show relevant log lines
echo ""
echo "--- Serial log (last 20 lines) ---"
tail -n 20 "${OUTPUTS_DIR}/firecracker.log"
echo "---"

# Verify via SSH if available
if command -v sshpass &>/dev/null; then
    log_info "Attempting to verify via SSH..."
    if ping -c 1 -W 2 172.20.0.2 >/dev/null 2>&1; then
        RESULT=$(sshpass -p root ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            root@172.20.0.2 \
            'df -h /mnt/drive9 2>/dev/null && ls /mnt/drive9/ 2>/dev/null || echo "not mounted"' \
            2>/dev/null || echo "SSH failed")
        echo ""
        echo "SSH verification result:"
        echo "$RESULT"
    else
        log_warn "VM not reachable via network yet"
    fi
else
    log_warn "sshpass not installed, skipping SSH verification"
    log_info "Install with: sudo apt-get install -y sshpass"
fi

# Enter interactive VM shell via SSH
if command -v sshpass &>/dev/null; then
    echo ""
    log_info "Entering VM shell (root@172.20.0.2). Type 'exit' to quit and stop Firecracker."
    echo ""
    script -q -c "sshpass -p root ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=error root@172.20.0.2" /dev/null || true
else
    echo ""
    log_warn "sshpass not installed. Install with: sudo apt-get install -y sshpass"
    log_info "Firecracker is running in the background. To connect manually:"
    echo "    sshpass -p root ssh -o StrictHostKeyChecking=no root@172.20.0.2"
    echo ""
    # Keep script running so user can see logs
    tail -f "${OUTPUTS_DIR}/firecracker.log" 2>/dev/null
fi

echo ""
log_info "Stopping Firecracker..."
pkill -f "${FC_BIN_PATTERN}" 2>/dev/null || true
# Also kill the background start-firecracker.sh script and any remaining tail
kill "$START_PID" 2>/dev/null || true
rm -f /tmp/firecracker-drive9.sock
log_info "Done."
