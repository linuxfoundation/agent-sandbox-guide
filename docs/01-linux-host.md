# 1. Linux host setup

[← Overview](../README.md) · Next: [Network allowlist and logging →](02-network.md)

## Prerequisites

- A dedicated x86_64 host. aarch64 works, but upstream tests Firecracker less on it. Bare metal, or a cloud VM with nested virtualization (for example AWS C8i/M8i/R8i or `*.metal`).
- Rootful Docker Engine 25 or later and system containerd 2.0 or later. This does **not** work with rootless Docker, Docker Desktop, WSL2, inside containers or Kubernetes pods, or in VMs without nested virtualization.
- The host holds no credentials other than the model-API credential.

```bash
ls -l /dev/kvm                                   # want crw-rw---- root kvm (0660 is enough)
grep . /sys/devices/system/cpu/vulnerabilities/* | grep -i vulnerable   # want no output
sudo swapoff -a && sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
docker version --format '{{.Server.Version}}'; containerd --version
```

The Firecracker [production host setup](https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md) also recommends disabling KSM and SMT (where tenants share cores), keeping microcode, kernel and firmware patched, and running a watchdog that kills hung `firecracker` processes.

## Install Kata Containers (Firecracker build)

Firecracker works **only with Kata's Go runtime**. The Go runtime is deprecated since Kata 4.0 but will not be removed before 5.0. You need the **`kata-go-static-*`** tarball. The plain `kata-static-*` tarball does not include Firecracker. The current release is 4.4.0, which ships Firecracker v1.17.0.

```bash
KATA_VER=4.4.0; ARCH=amd64          # or arm64
gh release download "$KATA_VER" -R kata-containers/kata-containers -p "kata-go-static-${KATA_VER}-${ARCH}.tar.zst"

# Compare against the digest GitHub publishes for the asset (don't copy digests from docs)
gh api "repos/kata-containers/kata-containers/releases/tags/${KATA_VER}" \
  --jq '.assets[] | select(.name|test("go-static")) | "\(.name) \(.digest)"'
sha256sum "kata-go-static-${KATA_VER}-${ARCH}.tar.zst"

sudo tar --zstd -xf "kata-go-static-${KATA_VER}-${ARCH}.tar.zst" -C /       # installs under /opt/kata
sudo ln -sf /opt/kata/bin/containerd-shim-kata-v2 /usr/local/bin/containerd-shim-kata-v2
sudo install -D -m 0644 /opt/kata/share/defaults/kata-containers/configuration-fc.toml \
     /etc/kata-containers/configuration.toml
```

> The older Kata how-to uses a `containerd-shim-kata-fc-v2` wrapper that sets `KATA_CONF_FILE`. Kata 4.x rejects that variable unless it points at one of the default `configuration.toml` paths. That is why the Firecracker config is copied to `/etc/kata-containers/configuration.toml`, which takes precedence over the default.

## Harden the Kata config

Edit `/etc/kata-containers/configuration.toml`. Set each key in the section where it already appears.

| Key | Value |
| --- | --- |
| `jailer_path` | `"/opt/kata/bin/jailer"`. If unset, Firecracker runs **without** the jail. |
| `enable_annotations` | `[]` |
| `disable_guest_seccomp` | `false` |
| `sandbox_cgroup_only` | `true` |
| `static_sandbox_resource_mgmt` | `true` |
| `default_vcpus` / `default_memory` | `4` / `4096` |
| `enable_debug`, `debug_console_enabled` | `false` |
| `enable_template` (in `[factory]`) | `false` |
| `entropy_source` | `"/dev/urandom"` |
| `kernel`, `image`, `kernel_params` | Leave the release values. |

```bash
grep -nE '^\s*(jailer_path|enable_annotations|disable_guest_seccomp|sandbox_cgroup_only|static_sandbox_resource_mgmt|default_vcpus|default_memory|enable_debug|debug_console_enabled|enable_template|entropy_source)\s*=' \
  /etc/kata-containers/configuration.toml
# Make the guest kernel and image immutable (run chattr -i before a Kata upgrade)
sudo find /opt/kata/share/kata-containers -type f \( -name 'vmlinu*' -o -name '*.img' \) -exec chattr +i {} +
```

## Block storage: containerd devmapper

Firecracker can't share host directories, so container storage must be block devices. Use an **LVM thin pool on a dedicated disk**. The loopback-file pool from the containerd docs is slow, doesn't survive a reboot, and has been reported failing under nested VMs.

```bash
DISK=/dev/sdb        # dedicated, empty disk; check with lsblk
sudo pvcreate "$DISK" && sudo vgcreate containerd "$DISK"
sudo lvcreate --wipesignatures y -n thinpool     containerd -l 95%VG
sudo lvcreate --wipesignatures y -n thinpoolmeta containerd -l 1%VG
sudo lvconvert -y --zero n -c 512K --thinpool containerd/thinpool --poolmetadata containerd/thinpoolmeta
sudo dmsetup ls | grep thinpool        # pool name is containerd-thinpool
```

Append [`config/containerd/devmapper.toml`](../config/containerd/devmapper.toml) to `/etc/containerd/config.toml`. **⚠ verify:** the section header depends on the config `version` your containerd uses. containerd 2.x should migrate v2-style configs.

```bash
sudo tee -a /etc/containerd/config.toml < config/containerd/devmapper.toml
sudo systemctl restart containerd && sudo ctr plugins ls | grep devmapper   # want: ok
```

For a quick throwaway test without a spare disk, use the loopback script in the [containerd devmapper docs](https://github.com/containerd/containerd/blob/main/docs/snapshotters/devmapper.md). The [Kata Firecracker how-to](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-kata-containers-with-firecracker.md) has a systemd unit that reloads it at boot.

## Register the runtime with Docker

Install [`config/docker/daemon.json`](../config/docker/daemon.json) as `/etc/docker/daemon.json`. Merge it by hand if you already have one.

```bash
sudo install -m 0644 config/docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
docker run --rm --runtime kata-fc alpine uname -r; uname -r     # kernels must differ
```

Switching Docker's image store hides existing images. They stay on disk, and reverting `daemon.json` brings them back. Check thin-pool usage with `sudo dmsetup status containerd-thinpool`. When it fills, writes fail. Free space with `docker system prune`.

---

Next: [Network allowlist and logging →](02-network.md)
