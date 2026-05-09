#!/bin/bash
set -euo pipefail

TAP_DEV="${TAP_DEV:-fc-tap0}"
VM_SUBNET="${VM_SUBNET:-172.20.0.0/30}"
HOST_IP="${HOST_IP:-172.20.0.1/30}"

echo "Setting up host networking for Firecracker..."

# Clean up old TAP if exists
sudo ip link del "${TAP_DEV}" 2>/dev/null || true

# Create TAP
sudo ip tuntap add dev "${TAP_DEV}" mode tap user "$(id -un)"
sudo ip addr add "${HOST_IP}" dev "${TAP_DEV}"
sudo ip link set "${TAP_DEV}" up

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Setup NAT (avoid duplicate rules)
if ! sudo iptables -t nat -C POSTROUTING -s "${VM_SUBNET}" -o eth0 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -s "${VM_SUBNET}" -o eth0 -j MASQUERADE
fi

echo "Host network ready: TAP=${TAP_DEV}, subnet=${VM_SUBNET}"
