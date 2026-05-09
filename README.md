# drive9 for Firecracker

Run the [drive9](https://drive9.ai) FUSE filesystem inside an AWS Firecracker
microVM.

This repository builds a FUSE-enabled Firecracker kernel, prepares a compact
Alpine rootfs with `drive9` installed, configures host TAP/NAT networking, and
starts a VM that mounts drive9 at boot. The rootfs stays reusable: your drive9
API key is injected at launch time and is never baked into the image.

## What It Builds

- A Linux 5.10 kernel based on Firecracker's microVM config, with
  `CONFIG_FUSE_FS=y`
- A 2 GB Alpine 3.19 rootfs with `fuse3`, OpenSSH, OpenRC, and the `drive9`
  binary
- A host-side `fc-tap0` interface with NAT for outbound VM traffic
- A one-command demo path that boots the VM, checks the mount, then opens an
  interactive VM shell

## Prerequisites

- Linux x86_64 with KVM available at `/dev/kvm`
- `curl`, `jq`, `sudo`
- `sshpass` if you want `make demo` to verify the mount and open the VM shell
  automatically
- `docker` if you prefer the alternate rootfs build path
- About 5 GB of disk space for Linux sources, rootfs, and Firecracker artifacts
- A configured host `drive9` CLI context

## Quick Start

Export the API key from your current drive9 context, then run the demo:

```bash
export DRIVE9_API_KEY="$(drive9 ctx show --json --reveal | jq -r '.api_key')"
make demo
```

To inspect the key before exporting it:

```bash
drive9 ctx show --reveal
```

`make demo` builds any missing artifacts, prepares networking, starts
Firecracker, checks whether drive9 mounted successfully, and then drops you into
the VM shell.

## Step-by-step Usage

Use the phased targets when you want to debug or cache individual steps:

```bash
# Build a custom Linux kernel with FUSE built in.
# First run usually takes 15-30 minutes.
make kernel

# Build the Alpine rootfs and install drive9.
# First run usually takes 2-5 minutes.
make rootfs

# Configure host TAP + NAT.
make network

# Start the VM in the foreground.
make start

# Run the full demo flow.
make demo
```

## Project Layout

```text
drive9-for-firecracker/
├── Makefile
├── README.md
├── scripts/
│   ├── build-kernel.sh        # Linux 5.10 + Firecracker config + FUSE
│   ├── build-rootfs.sh        # Alpine rootfs + fuse3 + sshd + drive9
│   ├── setup-host-network.sh  # TAP fc-tap0 + NAT + IP forwarding
│   ├── start-firecracker.sh   # Firecracker download, API config, VM start
│   └── run-drive9-demo.sh     # Build, boot, verify, open shell
└── outputs/                   # Build artifacts, ignored by git
    ├── vmlinux-custom
    ├── rootfs.ext4
    └── release-v1.15.1-x86_64/
```

## Configuration

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `DRIVE9_API_KEY` | Yes | - | drive9 API key injected into the VM at boot |
| `LINUX_VERSION` | No | `5.10.234` | Linux kernel version |
| `FC_RELEASE` | No | `v1.15.1` | Firecracker release |
| `ROOTFS_SIZE` | No | `2048` | Rootfs size in MB |
| `TAP_DEV` | No | `fc-tap0` | Host TAP device name |

## How The Key Is Passed

`start-firecracker.sh` reads `DRIVE9_API_KEY`, removes whitespace, and appends it
to Firecracker `boot_args` as `drive9_api_key=...`. The VM startup script reads
`/proc/cmdline` and uses the key to initialize the drive9 mount.

This keeps the rootfs image clean, but it is still a demo-oriented delivery
path: kernel command lines and Firecracker logs can be visible to host-side
operators. Treat `outputs/firecracker.log` as sensitive when running with a real
key.

## Network Topology

```text
Host: 172.20.0.1/30 (fc-tap0)
  |
  | TAP
  |
VM:   172.20.0.2/30 (eth0)
```

The host NAT rule is:

```bash
iptables -t nat -A POSTROUTING -s 172.20.0.0/30 -o eth0 -j MASQUERADE
```

## Example Session

The real Firecracker and kernel logs are verbose; these are the relevant
signals:

```text
$ make demo
[INFO] Step 1/4: Kernel already built, skipping
[INFO] Step 2/4: Rootfs already built, skipping
[INFO] Step 3/4: Setting up host network...
[INFO] Step 4/4: Starting Firecracker microVM...
[INFO] drive9 mount initiated successfully

SSH verification result:
Filesystem                Size      Used Available Use% Mounted on
/dev/root                 1.9G     40.9M      1.7G   2% /

[INFO] Entering VM shell (root@172.20.0.2). Type 'exit' to quit and stop Firecracker.

(none):~# drive9 fs ls
.mounted
hello-direct.txt

(none):~# ls /mnt/drive9
hello-direct.txt
```

## Cleanup

```bash
make clean      # Remove build artifacts and stop Firecracker
make distclean  # Also remove downloaded Linux sources and rootfs images
```

## Known Limitations

- The first kernel build is slow; later runs reuse completed artifacts.
- `/dev/fuse` is created by `devtmpfs` with restrictive permissions, so the
  rootfs startup script fixes permissions before mounting drive9.
- drive9's shadow store needs enough free space in the rootfs; the default
  2 GB image is intentionally larger than a minimal Alpine image.
- `make demo` is optimized for a local development host, not for production
  isolation or long-lived credential handling.
