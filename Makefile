# drive9-for-firecracker
# One-command setup for drive9 + FUSE on Firecracker microVMs

.PHONY: all kernel rootfs network start demo clean help

SHELL := /bin/bash
MAKEFLAGS += --no-print-directory

# Default target: run the full demo
all: demo

# Step 1: Download and build the custom kernel with FUSE built-in
kernel:
	@echo "==> Step 1/4: Building kernel with FUSE support..."
	@bash scripts/build-kernel.sh

# Step 2: Build the Alpine rootfs with drive9 and FUSE tools
rootfs:
	@echo "==> Step 2/4: Building rootfs with drive9 + FUSE..."
	@bash scripts/build-rootfs.sh

# Step 3: Setup host network (TAP + NAT)
network:
	@echo "==> Step 3/4: Setting up host networking..."
	@bash scripts/setup-host-network.sh

# Step 4: Start Firecracker and run drive9 demo
start: kernel rootfs network
	@echo "==> Step 4/4: Starting Firecracker microVM..."
	@bash scripts/start-firecracker.sh

# Full demo: start VM, run drive9, show results
demo:
	@bash scripts/run-drive9-demo.sh

# Clean build artifacts
clean:
	@echo "==> Cleaning build artifacts..."
	rm -rf outputs/linux-* outputs/alpine-minirootfs* outputs/tmp
	-pkill -f firecracker 2>/dev/null || true
	-sudo ip link del fc-tap0 2>/dev/null || true

# Deep clean: also remove downloaded sources
distclean: clean
	@echo "==> Deep clean: removing all downloaded sources..."
	rm -rf outputs/linux-* outputs/alpine-minirootfs* outputs/*.tar.gz outputs/tmp
	rm -f outputs/vmlinux-custom outputs/rootfs.ext4

help:
	@echo "drive9-for-firecracker — Makefile targets"
	@echo ""
	@echo "  make kernel      — Build custom Linux kernel with FUSE built-in"
	@echo "  make rootfs      — Build Alpine rootfs with drive9 + FUSE"
	@echo "  make network     — Setup host TAP + NAT"
	@echo "  make start       — Start Firecracker VM (runs kernel+rootfs+network)"
	@echo "  make demo        — One-command full demo (kernel → rootfs → network → start)"
	@echo "  make clean       — Remove build artifacts and stop Firecracker"
	@echo "  make distclean   — Deep clean including downloaded Linux sources"
	@echo "  make help        — Show this help"
	@echo ""
	@echo "Required environment variable:"
	@echo "  DRIVE9_API_KEY   — Your drive9 API key (for automatic mount in VM)"
	@echo ""
	@echo "Optional environment variables:"
	@echo "  FC_RELEASE       — Firecracker version (default: v1.15.1)"
	@echo "  LINUX_VERSION    — Kernel version (default: 5.10.234)"
