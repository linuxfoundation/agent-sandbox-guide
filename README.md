# Agent sandbox guide: coding agents in Firecracker microVMs

This guide shows how to set up a Linux or macOS workstation so each AI coding agent runs in its own Firecracker microVM. It supports [Claude Code, pi and opencode](docs/03-running-agents.md#choose-a-harness) as the agent harness. Outbound traffic is denied by default, allowed hosts are listed explicitly, and every connection attempt is logged.

It follows Anthropic's *Agent containment best practices*: the [getting started](https://support.claude.com/en/articles/17316076) and [sandboxing](https://support.claude.com/en/articles/17316105-agent-containment-best-practices-sandboxing-private-beta) articles. Those articles are private-beta **recommendations, not requirements**. Re-read them before you rely on this guide.

> **Status:** compiled 2026-11-24 from the articles and upstream docs. It has **not been run end to end**. Lines marked **⚠ verify** could not be confirmed from a primary source. Run the checks in [Verify before you trust it](docs/05-verify.md) on every new host.

## What you get

| Property | How |
| --- | --- |
| Own guest kernel per agent | Kata Containers (Go runtime) with Firecracker. The Firecracker process runs in the `jailer`. |
| No host files in the guest | No bind mounts. The workspace is streamed in with `docker exec … tar`. |
| No direct internet | The agent network is a Docker `--internal` bridge with no route out. |
| Outbound allowlist | A Squid egress proxy allows only listed `host:port` entries over CONNECT. Everything else returns 403 and is logged. |
| Credential never in the guest | A credential proxy adds the API key or [subscription token](docs/07-subscription-logins.md). The agent gets a placeholder. |
| Bypass attempts logged | Host firewall rules log and drop anything leaving the agent bridge. |
| Bounded runs | A turn limit for each harness, a hard wall-clock `timeout`, and `docker rm -f`. |
| Evidence | Squid log, credential-proxy log, kernel firewall log, Kata/containerd/docker journals, and the agent transcript. Keep them for 30 days or more. |

Never give an agent or target container `--privileged`, `--device`, `--cap-add`, or `--network host`. Don't connect agents to MCP servers or other tools that can write to external state.

## Architecture

```text
 trusted host (Linux with KVM)
 ┌───────────────────────────────────────────────────────────────────────────┐
 │  run-agent.sh  ──writes──▶  /var/log/agent-sandbox/{transcripts,squid,…}  │
 │                                                                           │
 │   br-agents  (docker --internal, 172.30.0.0/24, no default route)         │
 │   ┌────────────────────────────┐                                          │
 │   │ agent-N-net (runc, sleep)  │◀─ shares netns ─┐                        │
 │   │ 172.30.0.1N                │                 │                        │
 │   └────────────────────────────┘   ┌─────────────┴──────────────┐         │
 │                                    │ agent-N  (kata-fc microVM) │         │
 │                                    │ agent CLI, own kernel      │         │
 │                                    └──┬──────────────────────┬──┘         │
 │          HTTPS_PROXY 172.30.0.2:3128  │                      │ ANTHROPIC_BASE_URL 172.30.0.3:8080
 │   ┌───────────────────────────────────▼─┐  ┌─────────────────▼───────────┐│
 │   │ egress-proxy (Squid, runc)          │  │ cred-proxy (runc, RO fs)    ││
 │   │ allowlist, deny-all, access.log     │  │ adds real key, model paths  ││
 │   └─────────────────┬───────────────────┘  └──────────────┬──────────────┘│
 │   br-egress (normal bridge) ─────────────────────────────────▶ internet   │
 │                                                                           │
 │   iptables DOCKER-USER / INPUT: anything else from br-agents → LOG + DROP │
 └───────────────────────────────────────────────────────────────────────────┘
```

Firecracker does not filter packets itself. All egress control happens on the host side: the internal bridge, the two proxies, and the firewall rules.

## Pick your path

| Workstation | Path |
| --- | --- |
| Linux with KVM (bare metal, or a VM with nested virtualization) | Follow the steps below directly on the host. |
| Mac with M3 or later, macOS 15 or later | [macOS option A](docs/04-macos.md#option-a-local-linux-vm-with-nested-virtualization-m3-or-later-macos-15-or-later): a Lima Linux VM with nested virtualization, then the steps below inside it. Not upstream-tested. |
| Mac with M1, M2 or Intel, or any Mac if you prefer | [macOS option B](docs/04-macos.md#option-b-remote-linux-kvm-host-any-mac): a remote Linux KVM host, driven over SSH. |

## Steps

1. [Linux host setup](docs/01-linux-host.md): prerequisites, Kata + Firecracker install, config hardening, devmapper storage, Docker runtime.
2. [Network allowlist and logging](docs/02-network.md): internal network, Squid egress proxy, credential proxy, host firewall log and drop.
3. [Running an agent](docs/03-running-agents.md): choosing Claude Code, pi or opencode, building the agent image, and the `run-agent.sh` launcher.
4. [macOS workstations](docs/04-macos.md): Lima nested-virtualization VM, or a remote host.
5. [Verify before you trust it](docs/05-verify.md): isolation and egress checks, plus a supervised escape test.
6. [Logs and retention](docs/06-logging.md): where each log lives, and how to keep logs for 30 days or more.
7. [Subscription logins](docs/07-subscription-logins.md): Claude Team/Enterprise seats with Claude Code, and GitHub Copilot with opencode, without an API key.

## Repository layout

```text
README.md                         overview (this file)
docs/                             step-by-step pages
config/containerd/devmapper.toml  containerd devmapper snapshotter block
config/docker/daemon.json         Docker: containerd image store, devmapper, kata-fc runtime
config/firewall/iptables.sh       log + drop rules (Docker's default iptables backend)
config/firewall/agent-egress.nft  same rules for Docker's nftables backend
config/harness/                   pi and opencode configs that point them at the credential proxy
config/lima/agent-host.yaml       Lima VM for macOS option A
config/logging/                   logrotate config and daily kernel-log export
config/squid/                     Squid config and empty allowlist
docker/agent.Dockerfile           agent image (one harness: Claude Code, pi or opencode, plus tools)
scripts/run-agent.sh              launcher: preflight checks, companion + microVM, limits, transcript
```

## References

- Anthropic: [Agent containment: getting started](https://support.claude.com/en/articles/17316076) · [Sandboxing](https://support.claude.com/en/articles/17316105-agent-containment-best-practices-sandboxing-private-beta) · [How we contain Claude](https://www.anthropic.com/engineering/how-we-contain-claude) · [Agent SDK secure deployment](https://code.claude.com/docs/en/agent-sdk/secure-deployment)
- Firecracker: [prod host setup](https://github.com/firecracker-microvm/firecracker/blob/main/docs/prod-host-setup.md) · [kernel policy (4K pages)](https://github.com/firecracker-microvm/firecracker/blob/main/docs/kernel-policy.md)
- Kata: [releases](https://github.com/kata-containers/kata-containers/releases) · [Firecracker how-to](https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/how-to-use-kata-containers-with-firecracker.md)
- containerd: [devmapper snapshotter](https://github.com/containerd/containerd/blob/main/docs/snapshotters/devmapper.md)
- Docker: [alternative runtimes](https://docs.docker.com/engine/daemon/alternative-runtimes/) · [iptables](https://docs.docker.com/engine/network/firewall-iptables/) · [nftables](https://docs.docker.com/engine/network/firewall-nftables/)
- Squid: [ACL reference](https://www.squid-cache.org/Doc/config/acl/)
- Apple: [`isNestedVirtualizationSupported`](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration/isnestedvirtualizationsupported) · Lima: [lima-vm.io](https://lima-vm.io/)

## License

[MIT](LICENSE)
