# 4. macOS workstations

[← Running an agent](03-running-agents.md) · Next: [Verify before you trust it →](05-verify.md)

Firecracker needs KVM, and macOS has none. Docker Desktop's single shared VM (which mounts your home directory) does **not** count as a sandbox. There are two options.

## Option A: local Linux VM with nested virtualization (M3 or later, macOS 15 or later)

Apple's Virtualization.framework exposes nested virtualization to Linux guests only on **Apple M3 or later with macOS 15 or later**. M1, M2 and Intel Macs can't use this option. Use [option B](#option-b-remote-linux-kvm-host-any-mac) on them.

> **⚠ Not upstream-tested.** Third-party reports show Firecracker running inside Lima with nested virtualization. Nobody has published results for Kata, Firecracker and the jailer together under nested virtualization. One writeup found Kata's QEMU path hung and the loopback devmapper pool failed. Run every check in [Verify](05-verify.md) before you rely on this.

Install Lima 1.0 or later, create a raw disk for the thin pool, and start the VM from [`config/lima/agent-host.yaml`](../config/lima/agent-host.yaml):

```bash
brew install lima
limactl disk create agent-thinpool --size 200GiB --format raw
limactl create --name agent-host ./config/lima/agent-host.yaml && limactl start agent-host
limactl shell agent-host -- ls -l /dev/kvm          # must exist
limactl shell agent-host -- lsblk                   # find the extra disk (e.g. /dev/vdb)
```

The VM config:

- uses `vmType: vz` with `nestedVirtualization: true`
- runs stock Ubuntu arm64, whose kernel uses the 4K pages Firecracker requires
- mounts **no** host directories
- disables Lima's own containerd, because you install Docker and containerd yourself
- doesn't forward VM ports to the Mac's localhost
- attaches the raw disk unformatted for the LVM thin pool (**⚠ verify** the `format: false` key for your Lima version)

Get this repo into the VM without a mount, for example with `git clone` inside it. Then, inside the VM (`limactl shell agent-host`), follow [Linux host setup](01-linux-host.md), [Network](02-network.md) and [Running an agent](03-running-agents.md) unchanged, with these differences:

- `ARCH=arm64`, and build arm64 agent images.
- Use the extra disk as `DISK` in the devmapper step.
- Treat the Lima VM as the dedicated host. Keep no other credentials in it, and don't share it with other work.

Alternatives with the same M3 and macOS 15 requirement are UTM 4.6 or later (Apple Virtualization backend, nested virtualization on by default) and `tart run --nested`.

## Option B: remote Linux KVM host (any Mac)

This is the sandboxing article's recommended approach for Macs. Set up a Linux host or cloud instance with [Linux host setup](01-linux-host.md) through [Running an agent](03-running-agents.md), then drive it from the Mac:

```bash
rsync -a ./repo/ agent-host:/srv/agent-work/a1/
ssh agent-host 'sudo /usr/local/bin/run-agent.sh a1 11 /srv/agent-work/a1 "task…"'
rsync -a agent-host:/var/log/agent-sandbox/ ./agent-logs/      # pull evidence back
```

Don't forward your SSH agent (`ForwardAgent no`) and don't copy Mac credentials to the host.

---

Next: [Verify before you trust it →](05-verify.md)
